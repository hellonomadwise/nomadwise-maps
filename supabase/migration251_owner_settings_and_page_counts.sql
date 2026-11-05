-- Migration 251: Settings in the Owner account (email switches) and our
-- own count of page views and direction taps on the listing pages.
--
-- 1. owner_email_prefs: one row per owner email, made on first use.
--    monthly       the monthly performance email (built next; on by default)
--    chat_replies  the email when Nomadwise answers in Inbox & support
--    New requests and the emails about their claim and page changes are
--    always sent; there is no switch for them.
--    token: for the "Stop monthly updates" link in an email (no sign-in).
-- 2. page_counts: views and "Directions" taps per listing page per day,
--    counted by nomadmaps.io/prices.js on every nomadwise.io listing page
--    (once per visitor session per page, no cookies). PostHog only sees
--    visitors who accept cookies, so it undercounts (median 2 views a
--    page a month on 5 Nov 2026). The Performance tab and the monthly
--    email read these.

create table if not exists public.owner_email_prefs (
  email        text primary key,
  monthly      boolean not null default true,
  chat_replies boolean not null default true,
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  updated_at   timestamptz not null default now()
);
alter table public.owner_email_prefs enable row level security;

-- true unless the owner switched this email off
create or replace function public.owner_wants_email(p_email text, p_key text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select case p_key when 'monthly' then p.monthly
                       when 'chat_replies' then p.chat_replies end
       from public.owner_email_prefs p
      where p.email = lower(btrim(coalesce(p_email, '')))),
    true);
$function$;

-- The signed-in owner's switches (defaults until they change one).
create or replace function public.owner_email_prefs_get()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text := public.owner_email();
  p  public.owner_email_prefs%rowtype;
begin
  if em is null then
    raise exception 'Please sign in again.';
  end if;
  select * into p from public.owner_email_prefs where email = em;
  return jsonb_build_object(
    'monthly', coalesce(p.monthly, true),
    'chat_replies', coalesce(p.chat_replies, true));
end $function$;

create or replace function public.owner_email_prefs_set(p_key text, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text := public.owner_email();
begin
  if em is null then
    raise exception 'Please sign in again.';
  end if;
  if p_key not in ('monthly', 'chat_replies') or p_on is null then
    raise exception 'Unknown setting.';
  end if;
  insert into public.owner_email_prefs (email) values (em)
  on conflict (email) do nothing;
  update public.owner_email_prefs
     set monthly = case when p_key = 'monthly' then p_on else monthly end,
         chat_replies = case when p_key = 'chat_replies' then p_on else chat_replies end,
         updated_at = now()
   where email = em;
  return public.owner_email_prefs_get();
end $function$;

-- The link at the foot of an email: switch that email off, no sign-in.
create or replace function public.owner_email_pref_off(p_token text, p_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text;
begin
  if p_key not in ('monthly', 'chat_replies') then
    return jsonb_build_object('ok', false);
  end if;
  update public.owner_email_prefs
     set monthly = case when p_key = 'monthly' then false else monthly end,
         chat_replies = case when p_key = 'chat_replies' then false else chat_replies end,
         updated_at = now()
   where token = btrim(coalesce(p_token, ''))
  returning email into em;
  return jsonb_build_object('ok', em is not null);
end $function$;

-- The token for an owner's email links (made with the row if needed).
create or replace function public.owner_email_token(p_email text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  em text := lower(btrim(coalesce(p_email, '')));
  t  text;
begin
  if em = '' then return null; end if;
  insert into public.owner_email_prefs (email) values (em)
  on conflict (email) do nothing;
  select token into t from public.owner_email_prefs where email = em;
  return t;
end $function$;

revoke all on function public.owner_wants_email(text, text) from public, anon, authenticated;
revoke all on function public.owner_email_token(text) from public, anon, authenticated;
revoke all on function public.owner_email_prefs_get() from public, anon;
revoke all on function public.owner_email_prefs_set(text, boolean) from public, anon;
grant execute on function public.owner_email_prefs_get() to authenticated;
grant execute on function public.owner_email_prefs_set(text, boolean) to authenticated;
grant execute on function public.owner_email_pref_off(text, text) to anon, authenticated;

-- Replies from Nomadwise in Inbox & support: not emailed when the owner
-- switched them off (the messages are still marked, so they are not sent
-- later; they stay in the chat).
do $mig$
declare
  def text := pg_get_functiondef('public.chat_email_sync()'::regprocedure);
  old text := 'if words is not null and r.em is not null and r.em = r.owner_email then';
  new text := 'if words is not null and r.em is not null and r.em = r.owner_email'
              || E'\n         and public.owner_wants_email(r.em, ''chat_replies'') then';
begin
  if position(new in def) > 0 then
    return;
  end if;
  if (length(def) - length(replace(def, old, ''))) / length(old) <> 1 then
    raise exception 'migration 251: chat_email_sync is not as expected';
  end if;
  execute replace(def, old, new);
end
$mig$;

-- ---------------------------------------------------------- page counts
create table if not exists public.page_counts (
  venue_id uuid not null references public.venues(id) on delete cascade,
  kind     text not null check (kind in ('view', 'directions')),
  day      date not null,
  n        integer not null default 0,
  primary key (venue_id, kind, day)
);
alter table public.page_counts enable row level security;

-- Called by prices.js: one view per visitor session per page, and a tap
-- on the page's Directions link. Anyone may call it; it can only add 1
-- to a listing page that exists, and a page stops counting at 5,000 a day.
create or replace function public.page_hit(p_slug text, p_kind text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  slug_ text := lower(btrim(coalesce(p_slug, '')));
  vid   uuid;
begin
  if p_kind not in ('view', 'directions') or slug_ = '' or length(slug_) > 200 then
    return;
  end if;
  select id into vid from public.venues where webflow_slug = slug_ limit 1;
  if vid is null then
    select id into vid from public.venues where lower(webflow_slug) = slug_ limit 1;
  end if;
  if vid is null then
    return;
  end if;
  insert into public.page_counts as c (venue_id, kind, day, n)
  values (vid, p_kind, (now() at time zone 'utc')::date, 1)
  on conflict (venue_id, kind, day)
  do update set n = c.n + 1 where c.n < 5000;
end $function$;

revoke all on function public.page_hit(text, text) from public;
grant execute on function public.page_hit(text, text) to anon, authenticated;

-- ============================================================
-- Migration 72: who opens the claim page, and from where.
-- (Applied automatically by the build; nothing to paste.)
--
-- Every visit to nomadmaps.io/?claim is logged and pings the phone,
-- with the listing page it came from when the link on nomadwise.io
-- carries it (?claim=<slug>&from=/coworking/<slug>) and the browser's
-- referrer otherwise (Google, a newsletter, direct). Pings are capped
-- so a crawler cannot ring the phone all night; the log keeps every
-- row regardless.
--
-- Also: claim_search() matches a page slug exactly, so a link that
-- arrives as ?claim=<slug> lands on the right space at once.
-- ============================================================

create table if not exists public.claim_visits (
  id          uuid primary key default gen_random_uuid(),
  seed        text,            -- what ?claim= carried (a name or a slug)
  from_path   text,            -- the nomadwise.io page, when the link says
  referrer    text,            -- the browser's referrer, when it says
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_claim_visits_created on public.claim_visits(created_at desc);
alter table public.claim_visits enable row level security;
drop policy if exists "claim_visits admin" on public.claim_visits;
create policy "claim_visits admin" on public.claim_visits
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed  text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm   text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref   text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua    text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  v     record;
  what  text;
  whence text;
  recent int;
begin
  insert into public.claim_visits (seed, from_path, referrer, user_agent)
  values (seed, frm, ref, ua);

  -- No more than 30 pings an hour, however busy the page is.
  select count(*) into recent from public.claim_visits
   where created_at > now() - interval '1 hour';
  if recent > 30 then
    return;
  end if;

  -- Name the space when the seed is a slug or a name we hold.
  if seed is not null then
    select name, city into v from public.venues
     where webflow_slug = seed or name ilike seed
     limit 1;
  end if;
  what := case when v.name is not null
               then v.name || coalesce(' in ' || nullif(v.city, ''), '')
               when seed is not null then '"' || seed || '"'
               else 'the claim page' end;
  whence := case when frm is not null then 'from nomadwise.io' || frm
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www\.)?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    'Claim page opened',
    'Someone opened the claim page for ' || what || ', ' || whence || '.',
    'eyes');
end $$;
grant execute on function public.claim_opened(text, text, text, text) to anon, authenticated;

-- claim_search: an exact slug match first, then the name search.
create or replace function public.claim_search(p_query text)
returns table (
  id uuid, name text, city text, neighbourhood text, country text,
  webflow_slug text, on_site boolean, already_verified boolean)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.city, v.neighbourhood, v.country, v.webflow_slug,
         v.webflow_cms_id is not null,
         v.listing_tier = 'verified'
    from public.venues v
   where char_length(trim(p_query)) >= 2
     and (v.webflow_slug = trim(p_query)
          or v.name ilike '%' || trim(p_query) || '%')
     and coalesce(v.website_status, '') <> 'retired'
     and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
   order by (v.webflow_slug = trim(p_query)) desc,
            (v.webflow_cms_id is not null) desc, v.name
   limit 25;
$$;
grant execute on function public.claim_search(text) to anon, authenticated;

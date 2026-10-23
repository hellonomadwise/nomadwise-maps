-- ============================================================
-- Migration 210: "Suggest a place" for travellers.
--
-- Jonathan, 23 Oct 2026: build a page where anyone who knows a good
-- cafe or coworking space that is not on nomadwise.io yet can suggest
-- it (nomadmaps.io/?suggest). The old "Know an amazing spot?" link on
-- the Country pages went to an old Webflow form and was removed on
-- 22 Oct; this is its replacement.
--
-- A suggestion is not a Google place yet, just like a sign-up from the
-- old forms (migration 188). So it goes on the same list: Candidates,
-- "Asked to be listed or suggested", after the sign-ups (sort 150).
-- On its card a founder finds the place on Google and queues it, or
-- says why it is not for the site, exactly as for a sign-up. Nothing
-- reaches Webflow without Approve.
--
-- What a visitor gives: the place's name, cafe or coworking space, the
-- city or area, the country (optional), a link (Google Maps, website
-- or Instagram; optional) and why they recommend it (optional). No
-- account, no email.
--
-- Guard against abuse (the page is public):
--   * a blocked network (migration 164) is thanked and nothing is kept;
--   * at most 5 suggestions a day from one address (kept only as a
--     hash), at most 60 a day in all;
--   * a hidden field a person never fills (p_hp): filled means a
--     machine, thanked and ignored;
--   * the same place (name and city) suggested twice stays one card.
-- The founders' phones get one notice per suggestion.
--
-- Pure ASCII. Safe to apply twice. Nothing existing is changed except
-- the duplicate rule, which now also looks at the city (two cafes with
-- the same name in two cities are two places).
-- ============================================================

alter table public.candidate_signups add column if not exists note text;
alter table public.candidate_signups add column if not exists link text;
alter table public.candidate_signups add column if not exists suggested_from text;
alter table public.candidate_signups add column if not exists ip_hash text;

-- Same name and same email was one sign-up; now name, email and city.
drop index if exists public.candidate_signups_once;
create unique index if not exists candidate_signups_once_city
  on public.candidate_signups
     (lower(name), lower(coalesce(contact_email, '')), lower(coalesce(city, '')));

create index if not exists idx_candidate_signups_ip
  on public.candidate_signups (ip_hash, created_at);

create or replace function public.site_suggest_place(
  p_name    text,
  p_kind    text,
  p_city    text,
  p_country text default null,
  p_link    text default null,
  p_note    text default null,
  p_from    text default null,
  p_hp      text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  nm    text := nullif(left(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), 160), '');
  ct    text := nullif(left(btrim(regexp_replace(coalesce(p_city, ''), '\s+', ' ', 'g')), 120), '');
  co    text := nullif(left(btrim(coalesce(p_country, '')), 80), '');
  lk    text := nullif(left(btrim(coalesce(p_link, '')), 500), '');
  nt    text := nullif(left(btrim(coalesce(p_note, '')), 800), '');
  fr    text := nullif(left(btrim(coalesce(p_from, '')), 300), '');
  kd    text := case when lower(coalesce(p_kind, '')) = 'cafe' then 'cafe' else 'coworking' end;
  ip    inet := public.request_ip();
  iph   text;
  web   text;
  insta text;
  same  record;
  newid uuid;
begin
  if nm is null or length(nm) < 2 then
    raise exception 'Please add the name of the place.';
  end if;
  if ct is null or length(ct) < 2 then
    raise exception 'Please add the city or area it is in.';
  end if;

  -- A machine, or a blocked network: thanked, nothing kept.
  if nullif(btrim(coalesce(p_hp, '')), '') is not null then
    return jsonb_build_object('ok', true);
  end if;
  if ip is not null and public.blocked_network_of(ip) is not null then
    return jsonb_build_object('ok', true);
  end if;

  iph := case when ip is null then null else md5('nw-suggest:' || host(ip)) end;
  if iph is not null and (select count(*) from public.candidate_signups
                           where ip_hash = iph
                             and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Thank you for all your suggestions today. Please send more tomorrow.';
  end if;
  if (select count(*) from public.candidate_signups
       where form = 'Suggested by a visitor'
         and created_at > now() - interval '1 day') >= 60 then
    raise exception 'We have had a lot of suggestions today. Please try again tomorrow.';
  end if;

  -- The link: a website or an Instagram page goes where the card shows
  -- it; a Google Maps link is kept as the link.
  if lk is not null and lk !~* '^https?://' then
    lk := 'https://' || lk;
  end if;
  if lk ~* 'instagram\.com/' then
    insta := lk;
  elsif lk is not null and lk !~* '(google\.[a-z.]+/maps|maps\.app\.goo\.gl|goo\.gl/maps|maps\.google\.)' then
    web := lk;
  end if;

  -- Maybe already on the site: say so on the card.
  select v.name, v.city into same
    from public.venues v
   where lower(btrim(v.name)) = lower(nm)
   limit 1;

  insert into public.candidate_signups (
    sort, form, submitted_at, name, kind, city, country, website, instagram,
    link, note, suggested_from, ip_hash, flag)
  values (
    150, 'Suggested by a visitor', now(), nm, kd, ct, co, web, insta,
    lk, nt, fr, iph,
    case when same.name is not null
         then left('Maybe already listed: ' || same.name
                   || coalesce(' (' || nullif(same.city, '') || ')', ''), 200) end)
  on conflict do nothing
  returning id into newid;

  if newid is null then
    -- Already suggested: one card is enough.
    return jsonb_build_object('ok', true, 'again', true);
  end if;

  perform public.notify_phone(
    'A place was suggested',
    left(nm || ', ' || ct || coalesce(', ' || co, '') || ' (' || kd || ')'
         || coalesce(': ' || nt, ''), 200),
    'bulb');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.site_suggest_place(text, text, text, text, text, text, text, text) from public;
grant execute on function public.site_suggest_place(text, text, text, text, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

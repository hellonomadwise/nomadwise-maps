-- ============================================================
-- Migration 39 — privacy: the public activity feed must never
-- reveal WHO is WHERE right NOW.
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- A verified contribution places a named person at a specific
-- cafe. For a solo traveller that is a live location broadcast.
-- Fix at the database view level (so even raw API calls cannot
-- see it): the exact venue name only appears once the activity
-- is at least 24 hours old. Fresh activity shows the city only.
-- ============================================================

drop view if exists public.live_activity;

create view public.live_activity as
select
  coalesce(nullif(p.display_name, ''), 'Nomad') as display_name,
  p.avatar_url,
  s.user_id,
  s.kind,
  s.verified_at,
  -- who + exact place + now: never all three together.
  case when s.verified_at <= now() - interval '24 hours'
       then v.name end as venue_name,
  v.city
from public.submissions s
join public.profiles p on p.id = s.user_id
left join public.venues v on v.id = s.venue_id
where s.status = 'verified' and s.verified_at is not null
order by s.verified_at desc
limit 100;

grant select on public.live_activity to anon, authenticated;

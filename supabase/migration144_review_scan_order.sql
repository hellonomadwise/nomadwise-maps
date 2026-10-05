-- ============================================================
-- Migration 144: the nightly review scan reads 10 places a night, the
-- ones that matter first.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026: the scan read the reviews of 250 found places
-- a night, about 7,500 lookups a month on the kind of Google lookup
-- with only 1,000 free a month ("Place Details Enterprise +
-- Atmosphere"). It took about half of the daily Google limit by
-- itself. He set it to 10 a night: about 300 a month, inside the free
-- amount with room left for the app.
--
-- With so few, which ten matters. review_scan_due() gives the order:
--   1. places not read yet that something points at: another site
--      names them, or Google's own search returns them for a place to
--      work (migration 140). Their reviews and rating are what the
--      Candidates card is missing;
--   2. places not read yet that are coworking spaces (on Candidates);
--   3. the other places not read yet, the latest found first;
--   4. places read more than 30 days ago, the longest ago first.
-- A place that is already a space on Nomad Maps, or was turned down
-- on Candidates, is left out: its reviews change nothing.
--
-- Nothing here writes anything.
-- ============================================================

create or replace function public.review_scan_due(p_limit integer default 10)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'google_place_id', x.google_place_id, 'name', x.name) order by x.rn),
           '[]'::jsonb)
    from (select d.google_place_id, d.name,
                 row_number() over (
                   order by case
                              when d.signals_checked_at is null
                               and (coalesce(array_length(d.work_phrases, 1), 0) > 0
                                    or exists (select 1 from public.mention_places mp
                                                where mp.google_place_id = d.google_place_id
                                                  and mp.status = 'matched')) then 0
                              when d.signals_checked_at is null
                               and (coalesce(d.primary_type, '') = 'coworking_space'
                                    or d.name ~* 'cowork|co-work|co work|workspace|work ?space|work ?hub|wework')
                                then 1
                              when d.signals_checked_at is null then 2
                              else 3 end,
                            d.signals_checked_at asc nulls first,
                            d.fetched_at desc nulls last,
                            d.google_place_id) as rn
            from public.discovered_places d
           where (d.signals_checked_at is null
                  or d.signals_checked_at < now() - interval '30 days')
             and not exists (select 1 from public.venues v
                              where v.google_place_id = d.google_place_id)
             and not exists (select 1 from public.candidate_decisions c
                              where c.google_place_id = d.google_place_id
                                and c.decision = 'dismissed')) x
   where x.rn <= greatest(0, least(coalesce(p_limit, 10), 500))
$$;
revoke all on function public.review_scan_due(integer) from public, anon, authenticated;
grant execute on function public.review_scan_due(integer) to service_role;

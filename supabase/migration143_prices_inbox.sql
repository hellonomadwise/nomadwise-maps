-- ============================================================
-- Migration 143: the Price check list as an inbox.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Oct 2026, after "Choose a page" (migration 142): "same
-- with this area. For those that have been reviewed, cycle them."
--
-- The four spaces already checked sat at the top of the list (it ran
-- by name). admin_prices_spaces() now runs in three parts:
--   1. spaces with a change waiting for a Go, or one that needs a look;
--   2. spaces not dealt with yet, by name (as before);
--   3. spaces dealt with, the longest ago first, so that when the rest
--      is done the list comes round again and the stalest check is the
--      next one up.
-- A space is dealt with when its prices were looked at against its own
-- website, when a check was requested for it, or when a Go or a skip
-- was pressed on a change for it. A new change waiting for a Go brings
-- it back to the top by itself. "Checked" shows the spaces looked at,
-- the latest first. Searching still finds any space.
--
-- Each row also says where it stands ("ord": 0, 1 or 2) and when it
-- was last dealt with ("dealt_at").
--
-- Nothing here changes a price, a product or the website.
-- ============================================================

create or replace function public.admin_prices_spaces(
  p_q text default '', p_filter text default '', p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q   text := lower(btrim(coalesce(p_q, '')));
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  with s as (
    select v.id, v.name, v.city, v.country, v.webflow_slug, v.website,
           v.listing_owner_email is not null as owned,
           public.upgrade_page_is_live(v) as page_live,
           public.product_page_url(v) as page,
           count(*) filter (where p.status = 'live') as products,
           count(*) filter (where p.status = 'live' and p.checked_at is not null) as checked,
           count(*) filter (where p.status = 'live' and p.check_seen_at is not null) as seen,
           min(p.site_updated_at) filter (where p.status = 'live') as site_oldest,
           max(p.check_seen_at) as last_seen,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status = 'proposed') as waiting,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status in ('approved','undo_requested')) as on_the_way,
           (select count(*) from public.product_changes c
             where c.venue_id = v.id and c.status = 'failed') as failed,
           (select jsonb_build_object('note', r.note, 'at', r.requested_at)
              from public.price_checks r
             where r.venue_id = v.id and r.status = 'requested' limit 1) as request,
           (select max(r.requested_at) from public.price_checks r
             where r.venue_id = v.id and r.status = 'requested') as requested_at,
           -- the last time you decided on a change for it (a Go or a skip)
           (select max(c.decided_at) from public.product_changes c
             where c.venue_id = v.id and c.decided_at is not null) as last_decided
      from public.venues v
      join public.venue_products p on p.venue_id = v.id
     group by v.id
  )
  select coalesce(jsonb_agg(to_jsonb(x) - 'rn' order by x.rn), '[]'::jsonb) into out
    from (
      select y.*,
             -- An inbox: changes waiting for you, then the spaces not
             -- looked at yet, by name; the spaces dealt with last, the
             -- longest ago first, so the list comes round again. Under
             -- "Checked" the latest comes first.
             row_number() over (
               order by case when coalesce(p_filter, '') = 'checked' then 0 else y.ord end,
                        case when coalesce(p_filter, '') = 'checked' then y.dealt_at end desc nulls last,
                        case when y.ord = 2 and coalesce(p_filter, '') <> 'checked'
                             then y.dealt_at end asc nulls last,
                        y.name, y.id) as rn
        from (
      select s.*,
             -- 0 a change waits for your Go (or needs a look); 1 not
             -- dealt with yet; 2 dealt with: looked at against their
             -- website, a check requested, or a Go on its way
             case when s.waiting + s.failed > 0 then 0
                  when s.request is not null or s.on_the_way > 0
                    or s.seen > 0 or s.last_decided is not null then 2
                  else 1 end as ord,
             greatest(s.last_seen, s.last_decided, s.requested_at) as dealt_at
        from s
       where s.products > 0
         and (q = '' or lower(s.name) like '%' || q || '%'
              or lower(coalesce(s.city, '')) like '%' || q || '%'
              or lower(coalesce(s.country, '')) like '%' || q || '%'
              or lower(coalesce(s.webflow_slug, '')) like '%' || q || '%')
         and case coalesce(p_filter, '')
               when 'requested' then s.request is not null
               when 'waiting' then s.waiting + s.failed + s.on_the_way > 0
               when 'unchecked' then s.seen = 0
               when 'checked' then s.seen > 0
               else true end
        ) y
    ) x
   where x.rn <= greatest(1, least(coalesce(p_limit, 60), 300));
  return out;
end $$;

revoke all on function public.admin_prices_spaces(text, text, integer) from public, anon;
grant execute on function public.admin_prices_spaces(text, text, integer) to authenticated;

-- ============================================================
-- Migration 211: "Managed by its owner" only on pages someone claimed.
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-25. The green "Managed by its owner" label on nomadwise.io was
-- seen on a page nobody had claimed (Sierra Cartel). The label comes
-- from listing_has_owner() (migration 157), which only asked whether
-- an owner email is stored on the space and is not one of our tests.
-- That email can also be typed in by hand on the Listing plan page,
-- with no claim behind it, so a page could get the label unclaimed.
--
-- Now a space counts as having an owner when, as before, an owner
-- email is stored and it is not a test, AND one of these is true:
--   * a claim for this space was approved (free or paid), or
--   * a founder said by hand "not a test" on its claimed line in
--     Outreach (as before), or
--   * it is on Plus (Verified tier): a paid page is never shown as
--     "Claim this listing".
-- The ten-minute job already takes the label off any page this now
-- answers "no" for (webflow_sync.py, listing_owner_marks), and puts
-- it on a Plus page that had none. Nothing else changes.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.listing_has_owner(p_venue uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v  public.venues%rowtype;
  em text;
begin
  select * into v from public.venues where id = p_venue;
  if not found then return false; end if;

  -- A Plus page is always managed: never "Claim this listing".
  if coalesce(v.listing_tier, '') = 'verified' then
    return true;
  end if;

  em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');
  if em is null then return false; end if;

  -- "Not a test", said by hand on one of the space's claimed lines,
  -- holds for the space (as in outreach_auto_test, migration 149).
  if exists (select 1 from public.space_contacts h
              where h.venue_id = v.id and h.test_by = 'hand'
                and not h.is_test
                and h.stage in ('claimed', 'verified')) then
    return true;
  end if;
  -- One of our own test claims is not an owner.
  if exists (select 1 from public.space_contacts x
              where x.venue_id = v.id and x.is_test
                and x.stage in ('claimed', 'verified')) then
    return false;
  end if;
  -- An owner email typed in by hand is not a claim (CR-25).
  if not exists (select 1 from public.listing_claims c
                  where c.venue_id = v.id
                    and c.status in ('free', 'paid')) then
    return false;
  end if;
  return not coalesce(
    public.outreach_auto_test_email(em, v.listing_owner_name), false);
end $$;

revoke all on function public.listing_has_owner(uuid)
  from public, anon, authenticated;
grant execute on function public.listing_has_owner(uuid) to service_role;

-- The list the ten-minute job works through now also looks at Plus
-- pages with no owner email (they get the label too).
create or replace function public.listing_owner_marks()
returns table (venue_id uuid, cms_id text, name text, has_owner boolean)
language sql stable security definer set search_path = public as $$
  select w.id, w.webflow_cms_id, w.name, w.has_owner
    from (select v.id, v.webflow_cms_id, v.name,
                 coalesce(v.page_owner_mark, false) as marked,
                 v.page_owner_mark_tried_at as tried_at,
                 public.listing_has_owner(v.id) as has_owner
            from public.venues v
           where v.webflow_cms_id is not null
             and (nullif(btrim(coalesce(v.listing_owner_email, '')), '')
                    is not null
                  or coalesce(v.listing_tier, '') = 'verified'
                  or coalesce(v.page_owner_mark, false))) w
   where w.has_owner is distinct from w.marked
     -- a page that could not be written is asked for again later
     and (w.tried_at is null or w.tried_at < now() - interval '6 hours')
   order by w.name
   limit 60;
$$;

revoke all on function public.listing_owner_marks()
  from public, anon, authenticated;
grant execute on function public.listing_owner_marks() to service_role;

notify pgrst, 'reload schema';

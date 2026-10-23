-- ============================================================
-- Migration 216: Plus pages never say "Own or manage this space?".
-- (Applied automatically by the build; nothing to paste.)
--
-- CR-25. A Plus (Verified tier) page with no owner email saved, such as
-- SOKKOOL, had no "Managed by its owner" label, so it still showed
-- "Own or manage this space? Claim this listing for free". Now a Plus
-- page always counts as managed, and the ten-minute job gives it the
-- label.
-- Nothing else changes: as before, a space with an owner email (from a
-- claim, or added by hand for an owner's other locations, as for
-- Sierra Cartel's branches, Jonathan 23 Oct) counts as managed unless
-- it is one of our tests. (Migration 211, which would also have asked
-- for an approved claim, was not used.)
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
  em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');
  -- No owner email: only a Plus page counts (as before for the rest).
  if em is null and coalesce(v.listing_tier, '') <> 'verified' then
    return false;
  end if;

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
  -- A Plus page is always managed: never "Claim this listing".
  if coalesce(v.listing_tier, '') = 'verified' then
    return true;
  end if;
  if em is null then return false; end if;
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

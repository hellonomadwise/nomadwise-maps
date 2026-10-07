-- Migration 157: "Managed by its owner" on a claimed page, and the
-- end of Lisbon-Cowork's text put right.
--
-- 1. A page whose space has an owner went on saying "Own or manage
--    this space? Claim this listing for free" (seen on Lisbon-Cowork
--    an hour after its owner claimed it, 7 Oct 2026). The website sync
--    now marks such a page in its "Nomadwise Offers" field, and the
--    template shows "Managed by its owner" where that field is set
--    (docs/OWNER_ACCOUNT.md). This migration says which pages:
--      listing_has_owner(venue)  an owner's address is on the space,
--                                and the claim is not one of our tests
--      listing_owner_marks()     the pages whose mark is not yet what
--                                it should be (what the sync asks for)
--      venues.page_owner_mark    what the page was last told
--      venues.page_owner_mark_tried_at  when a write last failed
--
-- 2. Lisbon-Cowork's owner saved his description while the limit was
--    still 3,000 characters (raised to 8,000 in migration 156): he
--    trimmed words to fit and the save then cut the end mid-word. The
--    page was tidied by hand that afternoon (Jonathan: "only tidy the
--    endings"); this puts the same two endings into the stored copies,
--    so his Owner account opens with the tidy text and a later sync
--    does not write the cut text back.

alter table public.venues
  add column if not exists page_owner_mark boolean,
  add column if not exists page_owner_mark_tried_at timestamptz;

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
  return not coalesce(
    public.outreach_auto_test_email(em, v.listing_owner_name), false);
end $$;

revoke all on function public.listing_has_owner(uuid)
  from public, anon, authenticated;
grant execute on function public.listing_has_owner(uuid) to service_role;

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

-- Five pages still carry the old discount button's label, the words
-- "Nomadwise Offers", in that field (shown nowhere on the page):
-- SOKKOOL, DEOS, Setter Ubud, Working on Air, AT 06. The template will
-- read "field is set" as "has an owner", so those of the five without
-- an owner are noted here as marked, and the sync then empties them.
-- (Those with an owner are picked up like any other owned page, and
-- get the mark in place of the label.)
update public.venues v
   set page_owner_mark = true
 where v.page_owner_mark is null
   and v.webflow_cms_id in ('67d78a0bd01eb8fd6ab57efe',
                            '67ba680ec6e7b846dc15ffa4',
                            '66f857f0ac399ec84dac1ff0',
                            '6613fb8149a091e1a4d49da8',
                            '65fa86d0e0379bf78d5245b3')
   and not public.listing_has_owner(v.id);

-- ---------------------------------------------------------------
-- 2. Lisbon-Cowork (Webflow item 6809cff65b7d6598c8b425e1): the two
--    endings, in what is on the page and in his own drafts. Each
--    update only touches a text that still has the cut ending.
update public.venues v
   set owner_content = jsonb_set(
         v.owner_content, '{description}',
         to_jsonb(regexp_replace(
           regexp_replace(
             v.owner_content->>'description',
             'Lisbon-Cowork offersl a well-balanced s\s*$',
             'Lisbon-Cowork offers a well-balanced setup in one of Lisbon'
               || U&'\2019' || 's most charming neighborhoods.'),
           'views of the Tagus River(\s*\n)',
           'views of the Tagus River.\1')))
 where v.webflow_cms_id = '6809cff65b7d6598c8b425e1'
   and v.owner_content->>'description'
         ~ 'Lisbon-Cowork offersl a well-balanced s\s*$';

update public.owner_drafts d
   set draft = jsonb_set(
         d.draft, '{description}',
         to_jsonb(regexp_replace(
           regexp_replace(
             d.draft->>'description',
             'Lisbon-Cowork offersl a well-balanced s\s*$',
             'Lisbon-Cowork offers a well-balanced setup in one of Lisbon'
               || U&'\2019' || 's most charming neighborhoods.'),
           'views of the Tagus River(\s*\n)',
           'views of the Tagus River.\1')))
  from public.venues v
 where v.id = d.venue_id
   and v.webflow_cms_id = '6809cff65b7d6598c8b425e1'
   and d.draft->>'description'
         ~ 'Lisbon-Cowork offersl a well-balanced s\s*$';

-- The page's own text as last copied (what the Owner account compares
-- with): the same tidy-up, so the two do not drift apart for a night.
update public.venues v
   set page_description = regexp_replace(
         regexp_replace(
           v.page_description,
           'Lisbon-Cowork offersl a well-balanced s\s*$',
           'Lisbon-Cowork offers a well-balanced setup in one of Lisbon'
             || U&'\2019' || 's most charming neighborhoods.'),
         'views of the Tagus River(\s*\n)',
         'views of the Tagus River.\1')
 where v.webflow_cms_id = '6809cff65b7d6598c8b425e1'
   and v.page_description ~ 'Lisbon-Cowork offersl a well-balanced s\s*$';

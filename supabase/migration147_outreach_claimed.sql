-- ============================================================
-- Migration 147: Outreach shows the spaces that have claimed.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Oct 2026: Outreach said "Claimed 0" while three spaces
-- had claimed their page (Westerwelle Startup Haus Arusha, Place
-- Coworking Phuket, Kopi Club).
--
-- Why: a contact only moved to Claimed when a claim arrived AFTER
-- Outreach was built, and only when the claim's address was already a
-- contact's address. Spaces that claimed earlier, or with an address
-- we did not hold, were never in the list at all.
--
-- Now the space itself decides, the same way the Money card counts:
--   * a space with an owner on record is Claimed (Verified when it is
--     on the Verified plan);
--   * its contact is the one with the owner's address, or the one for
--     that space; when there is none, one is made (source 'claim');
--   * it moves when the owner is put on the space (a claim approved),
--     not when a claim is merely started, so a claim that was started
--     and dropped no longer shows as Claimed;
--   * an owner taken off a space: the contact goes to "Not now" with a
--     dated note, so nobody is written to by accident; one owner
--     replaced by another: the old owner's line does the same and lets
--     go of the space;
--   * the trigger never stops a claim or a payment from being saved:
--     if the bookkeeping here fails, it warns and steps aside.
-- At the end every space that already has an owner is brought in.
-- ============================================================

-- A contact can now come from a claim.
alter table public.space_contacts drop constraint if exists space_contacts_source_check;
alter table public.space_contacts add constraint space_contacts_source_check
  check (source in ('email', 'webflow_form', 'listing', 'prospect', 'enquiry', 'manual', 'claim'));

-- One space: make Outreach agree with the owner on record.
-- Returns what it did, for the checks.
create or replace function public.outreach_owner_sync(p_venue uuid, p_today boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v        public.venues%rowtype;
  em       text;
  want     text;
  cid      uuid;      -- the contact for this space
  eid      uuid;      -- the contact with the owner's address
  evenue   uuid;
  at_      timestamptz;
  line     text;
  r        record;
  did      text := 'kept';
begin
  select * into v from public.venues where id = p_venue;
  if not found then return 'no space'; end if;
  em := nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '');

  -- ---------------------------------------------- no owner (any more)
  if em is null and coalesce(v.listing_tier, 'free') <> 'verified' then
    update public.space_contacts c
       set stage = case when c.unsubscribed_at is not null then 'unsubscribed' else 'not_now' end,
           notes = concat_ws(E'\n', nullif(c.notes, ''),
                             'Owner taken off ' || coalesce(v.name, 'the space') || ' on '
                             || to_char(now(), 'DD Mon YYYY') || '.')
     where c.venue_id = v.id and c.stage in ('claimed', 'verified');
    if found then return 'owner gone'; end if;
    return 'no owner';
  end if;

  want := case when coalesce(v.listing_tier, 'free') = 'verified' then 'verified' else 'claimed' end;

  -- When they claimed, for the note: the claim's own date; today when
  -- this runs as the owner is put on; otherwise unknown, and no date
  -- is written.
  select max(coalesce(k.approved_at, k.paid_at)) into at_
    from public.listing_claims k
   where k.venue_id = v.id and k.status in ('paid', 'free');
  if at_ is null and p_today then at_ := now(); end if;
  line := 'Claimed ' || coalesce(v.name, 'their page')
          || coalesce(' on ' || to_char(at_, 'DD Mon YYYY'), '') || '.';

  -- The contact with the owner's address, when it is free to stand for
  -- this space (it has no space yet, or this one).
  if em is not null then
    select c.id, c.venue_id into eid, evenue
      from public.space_contacts c where lower(c.email) = em;
    if eid is not null and evenue is not null and evenue <> v.id then
      eid := null;            -- that person's contact is another space's
    end if;
  end if;

  if eid is not null then
    -- A contact made by itself for the listed space, never written to
    -- and with nothing noted, is folded into the owner's contact: one
    -- space, one line.
    for r in
      select c.* from public.space_contacts c
       where c.venue_id = v.id and c.id <> eid
    loop
      if r.source = 'listing' and r.last_in_at is null and r.last_out_at is null
         and coalesce(btrim(r.notes), '') = ''
         and not exists (select 1 from public.outreach_messages m where m.contact_id = r.id) then
        update public.space_contacts c
           set website   = coalesce(c.website, r.website),
               instagram = coalesce(c.instagram, r.instagram),
               kind      = coalesce(c.kind, r.kind),
               city      = coalesce(c.city, r.city),
               country   = coalesce(c.country, r.country)
         where c.id = eid;
        delete from public.space_contacts c where c.id = r.id;
      end if;
    end loop;
    update public.space_contacts c
       set venue_id = v.id,
           notes = case when c.stage in ('claimed', 'verified') then c.notes
                        else concat_ws(E'\n', nullif(c.notes, ''), line) end,
           -- A line made for the listed space is no longer "unclaimed".
           source = case when c.source = 'listing' then 'claim' else c.source end,
           stage = want
     where c.id = eid
       and (c.stage <> want or c.venue_id is distinct from v.id or c.source = 'listing');
    if found then did := want; end if;
  end if;

  -- Every (other) contact for this space follows it.
  update public.space_contacts c
     set notes = case when c.stage in ('claimed', 'verified') then c.notes
                      else concat_ws(E'\n', nullif(c.notes, ''), line) end,
         -- A line made for the listed space is no longer "unclaimed".
         source = case when c.source = 'listing' then 'claim' else c.source end,
         -- The owner's address, when the contact has none and nobody
         -- else holds it.
         email = case when c.email is null and em is not null
                       and c.id = (select c2.id from public.space_contacts c2
                                    where c2.venue_id = v.id
                                    order by c2.created_at, c2.id limit 1)
                       and not exists (select 1 from public.space_contacts c3
                                        where lower(c3.email) = em)
                      then em else c.email end,
         stage = want
   where c.venue_id = v.id
     and (eid is null or c.id <> eid)
     and (c.stage <> want or c.source = 'listing'
          -- at the right stage already, and the owner's address has
          -- only now come (a plan set by hand first, say)
          or (c.email is null and em is not null
              and c.id = (select c2.id from public.space_contacts c2
                           where c2.venue_id = v.id
                           order by c2.created_at, c2.id limit 1)
              and not exists (select 1 from public.space_contacts c3
                               where lower(c3.email) = em)));
  if found then did := want; end if;

  -- Nobody yet: the space gets its line.
  select c.id into cid from public.space_contacts c where c.venue_id = v.id limit 1;
  if cid is null then
    insert into public.space_contacts
      (venue_id, space_name, kind, city, country, person_name, email,
       website, instagram, source, stage, stage_at, notes)
    values
      (v.id, v.name, v.type, nullif(btrim(v.city), ''), nullif(btrim(v.country), ''),
       nullif(btrim(v.listing_owner_name), ''),
       case when em is not null
             and not exists (select 1 from public.space_contacts c where lower(c.email) = em)
            then em end,
       nullif(btrim(v.website), ''), nullif(btrim(v.instagram), ''),
       'claim', want, coalesce(at_, now()), line);
    did := 'added ' || want;
  end if;
  return did;
end $$;
revoke all on function public.outreach_owner_sync(uuid, boolean) from public, anon, authenticated;
grant execute on function public.outreach_owner_sync(uuid, boolean) to service_role;

-- It runs whenever a space's owner or plan changes. This takes over
-- from the two older triggers: "a claim arrived" (which also fired for
-- claims that were started and dropped) and "the plan became Verified".
create or replace function public.outreach_on_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if btrim(coalesce(new.listing_owner_email, '')) <> ''
       or coalesce(new.listing_tier, 'free') = 'verified' then
      perform public.outreach_owner_sync(new.id, true);
    end if;
  elsif new.listing_owner_email is distinct from old.listing_owner_email
     or new.listing_tier is distinct from old.listing_tier then
    -- One owner replaced by another (a second claim approved, or the
    -- address corrected): the line with the previous owner's address
    -- steps aside and lets go of the space.
    if btrim(coalesce(old.listing_owner_email, '')) <> ''
       and btrim(coalesce(new.listing_owner_email, '')) <> ''
       and lower(btrim(old.listing_owner_email)) <> lower(btrim(new.listing_owner_email)) then
      update public.space_contacts c
         set stage = case when c.unsubscribed_at is not null then 'unsubscribed' else 'not_now' end,
             venue_id = null,
             notes = concat_ws(E'\n', nullif(c.notes, ''),
                               'No longer the owner of ' || coalesce(new.name, 'the space') || ' on '
                               || to_char(now(), 'DD Mon YYYY') || '.')
       where c.venue_id = new.id
         and lower(c.email) = lower(btrim(old.listing_owner_email))
         and c.stage in ('claimed', 'verified');
    end if;
    perform public.outreach_owner_sync(new.id, true);
  end if;
  return new;
exception when others then
  -- Outreach is bookkeeping: it never stops a claim or a payment from
  -- being saved. (Two approvals at the same instant for one address
  -- could otherwise trip the one-contact-per-address rule.)
  raise warning 'outreach_on_owner(%): %', new.id, sqlerrm;
  return new;
end $$;
drop trigger if exists outreach_on_owner on public.venues;
create trigger outreach_on_owner
  after insert or update of listing_owner_email, listing_tier on public.venues
  for each row execute function public.outreach_on_owner();

drop trigger if exists outreach_on_claim on public.listing_claims;
drop trigger if exists outreach_on_verified on public.venues;
drop function if exists public.outreach_on_claim();
drop function if exists public.outreach_on_verified();

-- The tabs' numbers: Claimed and Verified count spaces, so a space with
-- two lines (its own, and a person who wrote to us) is one. The rest
-- is as migration 124.
create or replace function public.admin_outreach_counts(p_group text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select stage,
                             count(distinct case when stage in ('claimed', 'verified')
                                                 then coalesce(venue_id, id) else id end) n
                        from public.space_contacts
                       where coalesce(p_group, '') = '' or public.outreach_group(source) = p_group
                       group by stage) x), '{}'::jsonb)
    || jsonb_build_object(
         '_wrote',    (select count(*) from public.space_contacts where public.outreach_group(source) = 'wrote'),
         '_listed',   (select count(*) from public.space_contacts where public.outreach_group(source) = 'listed'),
         '_prospect', (select count(*) from public.space_contacts where public.outreach_group(source) = 'prospect'),
         '_no_email', (select count(*) from public.space_contacts
                        where email is null
                          and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)))
  end;
$$;
revoke all on function public.admin_outreach_counts(text) from public, anon;
grant execute on function public.admin_outreach_counts(text) to authenticated;

-- Every space that has an owner today.
do $$
declare r record;
begin
  for r in
    select v.id from public.venues v
     where btrim(coalesce(v.listing_owner_email, '')) <> ''
        or coalesce(v.listing_tier, 'free') = 'verified'
     order by v.name
  loop
    perform public.outreach_owner_sync(r.id);
  end loop;
end $$;

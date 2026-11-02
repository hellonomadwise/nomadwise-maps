-- ============================================================
-- Migration 236: every enquiry for a space is remembered on its
-- Outreach box, passed on or not.
-- (Applied automatically by the build; nothing to paste.)
--
-- Leonie, 2 Nov 2026, on Immy's enquiry for Fora (22 Manchester
-- Square): we asked Immy for more details and heard nothing, so it was
-- never passed on. "Maybe we can save somewhere that the coworking
-- space has had a request ... so we can bring it up whenever we might
-- outreach to them."
--   admin_venue_customers   per space: 'asked' (every enquiry that
--                           named it), 'last_asked', and as before
--                           'sent' (passed on or sent straight),
--                           'booked' and 'last'. A space with enquiries
--                           and none passed on now shows too (sent 0).
--   outreach_box_for_venue  makes the space's Outreach box when it has
--                           none (unclaimed spaces only, as "Bring in
--                           listed spaces" does), so the enquiry is
--                           there when we write to them.
--   enquiries trigger       calls it for each new enquiry with a space.
--   Backfill: the three spaces with enquiries and no box yet.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.admin_venue_customers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_object_agg(t.venue_id::text, jsonb_build_object(
             'asked', t.asked, 'last_asked', t.last_asked,
             'sent', t.sent, 'booked', t.booked, 'last', t.last_at))
      from (select e.venue_id,
                   count(*) as asked,
                   max(e.created_at) as last_asked,
                   count(*) filter (where e.status in ('passed', 'sent')) as sent,
                   count(*) filter (where e.outcome = 'booked') as booked,
                   max(coalesce(e.passed_at, e.sent_at))
                     filter (where e.status in ('passed', 'sent')) as last_at
              from public.enquiries e
             where e.venue_id is not null
             group by e.venue_id) t), '{}'::jsonb);
end $$;
revoke all on function public.admin_venue_customers() from public, anon;
grant execute on function public.admin_venue_customers() to authenticated;

-- The space's Outreach box, made when it has none: the same as "Bring in
-- listed spaces" (admin_outreach_add_listed) for one space. Nothing for
-- a claimed or Premium space (they are talked to in Chats).
create or replace function public.outreach_box_for_venue(p_venue uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v   public.venues%rowtype;
  em  text;
  cid uuid;
begin
  if p_venue is null then return null; end if;
  select c.id into cid from public.space_contacts c where c.venue_id = p_venue limit 1;
  if cid is not null then return cid; end if;
  select * into v from public.venues where id = p_venue;
  if not found
     or coalesce(trim(v.listing_owner_email), '') <> ''
     or coalesce(v.listing_tier, 'free') = 'verified'
     or coalesce(v.business_status, '') = 'CLOSED_PERMANENTLY' then
    return null;
  end if;
  select lower(trim(x)) into em
    from unnest(coalesce(v.contact_emails, '{}')) x
   where position('@' in x) > 1 limit 1;
  -- one contact per address, as in add_listed
  if em is not null and exists (select 1 from public.space_contacts c where lower(c.email) = em) then
    em := null;
  end if;
  insert into public.space_contacts
    (venue_id, space_name, kind, city, country, email, website, instagram, source, stage)
  values (v.id, v.name, v.type, nullif(trim(v.city), ''), nullif(trim(v.country), ''),
          em, nullif(trim(v.website), ''), nullif(trim(v.instagram), ''), 'listing', 'new')
  returning id into cid;
  return cid;
end $$;
revoke all on function public.outreach_box_for_venue(uuid) from public, anon, authenticated;

create or replace function public.enquiry_outreach_box()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.venue_id is not null then
    begin
      perform public.outreach_box_for_venue(new.venue_id);
    exception when others then
      null;  -- never in the way of an enquiry
    end;
  end if;
  return new;
end $$;
revoke all on function public.enquiry_outreach_box() from public, anon, authenticated;

drop trigger if exists enquiry_outreach_box on public.enquiries;
create trigger enquiry_outreach_box
  after insert or update of venue_id on public.enquiries
  for each row execute function public.enquiry_outreach_box();

select public.outreach_box_for_venue(x.venue_id)
  from (select distinct e.venue_id from public.enquiries e where e.venue_id is not null) x;

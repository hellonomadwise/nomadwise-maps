-- 178: a page we approve gets a line in Outreach once it is live, and
-- the test of new pages is counted from live to signed in.
--
-- Jonathan, 9 Oct 2026, on Level39 (shortlisted, approved, published
-- the same day): "i want to capture this into a cold outreach, if i
-- can find an email address to contact ... i want to test the whole
-- shortlisting, making live, and then sending them a hello, and that
-- they can claim their free listing and access their members areas,
-- to see how many actually sign up". Until now such a space reached
-- Outreach only when "Bring in listed spaces" was pressed.
--
--   venues.new_page_live_at   when a page approved in Pages went live
--                             (set by itself as the sync marks it
--                             released; kept even when the space's
--                             Outreach line changes or is folded)
--   outreach_new_page_line()  the space's line in Outreach, made the
--                             way "Bring in listed spaces" makes one
--                             (group "Listed, unclaimed", stage New),
--                             unless the space has a line or an owner
--   outreach_venues_to_check  new pages are read for an address first
--   invite_new_page           the hello, picked when writing to one
--   admin_new_pages()         each new page and how far it got: live,
--                             an address, written to, opened the claim
--                             page, claimed, in its Owner account
--
-- Nothing is sent by itself. Pages approved since 6 Oct 2026 that are
-- live already are counted from the moment this is applied.
-- Pure ASCII. Safe to apply twice.

alter table public.venues
  add column if not exists new_page_live_at timestamptz;
create index if not exists venues_new_page_live_idx
  on public.venues (new_page_live_at desc) where new_page_live_at is not null;

-- ------------------------------------------------ the line in Outreach
create or replace function public.outreach_new_page_line(p_venue uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v   record;
  em  text;
  cid uuid;
begin
  select * into v from public.venues where id = p_venue;
  if v.id is null then return null; end if;
  -- a line already (they wrote to us, or were brought in): that one
  select c.id into cid from public.space_contacts c
   where c.venue_id = v.id order by c.is_test, c.created_at limit 1;
  if cid is not null then return cid; end if;
  -- claimed, Verified or closed: not a cold hello
  if btrim(coalesce(v.listing_owner_email, '')) <> ''
     or coalesce(v.listing_tier, 'free') = 'verified'
     or coalesce(v.business_status, '') = 'CLOSED_PERMANENTLY' then
    return null;
  end if;
  -- an address already found on its own website, unless another line
  -- holds it (one line per address)
  select lower(btrim(x)) into em
    from unnest(coalesce(v.contact_emails, '{}'::text[])) x
   where position('@' in x) > 1
     and not exists (select 1 from public.space_contacts c
                      where lower(c.email) = lower(btrim(x)))
   limit 1;
  insert into public.space_contacts
    (venue_id, space_name, kind, city, country, email, website, instagram,
     source, stage, notes)
  values
    (v.id, v.name, v.type, nullif(btrim(coalesce(v.city, '')), ''),
     nullif(btrim(coalesce(v.country, '')), ''), em,
     nullif(btrim(coalesce(v.website, '')), ''),
     nullif(btrim(coalesce(v.instagram, '')), ''),
     'listing', 'new',
     'New page, live ' || to_char(coalesce(v.new_page_live_at, now()) at time zone 'utc', 'YYYY-MM-DD'))
  returning id into cid;
  return cid;
end $$;
revoke all on function public.outreach_new_page_line(uuid) from public, anon, authenticated;

-- ------------------------------------------------ when the page goes live
-- Before: the moment is kept on the space (the first time only).
create or replace function public.venues_new_page_mark()
returns trigger language plpgsql as $$
begin
  if new.website_status = 'released'
     and old.website_status is distinct from 'released'
     and new.website_approved_at is not null
     and new.new_page_live_at is null then
    new.new_page_live_at := now();
  end if;
  return new;
end $$;
drop trigger if exists venues_new_page_mark on public.venues;
create trigger venues_new_page_mark
  before update of website_status on public.venues
  for each row execute function public.venues_new_page_mark();

-- After: the line in Outreach. Never stops the sync's own update.
create or replace function public.venues_new_page_line()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.outreach_new_page_line(new.id);
  return null;
exception when others then
  raise warning 'venues_new_page_line: %', sqlerrm;
  return null;
end $$;
drop trigger if exists venues_new_page_line on public.venues;
create trigger venues_new_page_line
  after update of website_status, new_page_live_at on public.venues
  for each row
  when (new.new_page_live_at is not null and old.new_page_live_at is null)
  execute function public.venues_new_page_line();

-- Pages approved since 6 Oct 2026 and live already (the trigger above
-- makes their lines).
update public.venues
   set new_page_live_at = coalesce(website_synced_at, now())
 where new_page_live_at is null
   and website_status = 'released'
   and website_approved_at >= timestamptz '2026-10-06 00:00:00+00';

-- ------------------------------------------------ addresses: new pages first
create or replace function public.outreach_venues_to_check(p_limit integer default 10)
returns table (id uuid, name text, website text, contact_emails text[])
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.website, v.contact_emails
    from public.venues v
   where v.contact_checked_at is null
     and coalesce(trim(v.website), '') <> ''
     and exists (select 1 from public.space_contacts c
                  where c.venue_id = v.id and c.email is null)
   order by v.new_page_live_at desc nulls last, v.name
   limit greatest(0, least(coalesce(p_limit, 10), 50));
$$;
revoke all on function public.outreach_venues_to_check(integer) from public, anon, authenticated;
grant execute on function public.outreach_venues_to_check(integer) to service_role;

-- ------------------------------------------------ the hello
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('invite_new_page', 'Hello: a new page of ours (first email)',
 '{space} is now on Nomadwise',
 'Hi there,

We have added {space} to nomadwise.io, where remote workers and digital nomads look for places to work from. Here is the page: {page_link}

The page is free, and so is claiming it. Once it is yours, you can update your opening hours and contact details, and add your own photos, description and prices, from your own Owner account. Claim it here: {claim_link}

If you would like more, Verified adds the Verified badge, a place above every free listing in your area and enquiries straight to your inbox, for {price_words}, monthly or yearly, cancel any time.

We will not write again unless you reply.

{signoff}', 'outbound', 45)
on conflict (key) do nothing;

-- ------------------------------------------------ how far each got
create or replace function public.admin_new_pages()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  with np as (
    select v.id, v.name, v.type, v.city, v.country, v.webflow_slug, v.website,
           v.new_page_live_at as live_at, v.contact_checked_at, v.contact_emails,
           btrim(coalesce(v.listing_owner_email, '')) <> '' as has_owner
      from public.venues v
     where v.new_page_live_at is not null
  ),
  looks as (
    select l.venue_id, max(l.last_at) as last_at
      from public.claim_lookers(120) l
     where l.venue_id in (select np.id from np)
     group by l.venue_id
  ),
  act as (
    select a.venue_id, (a.signed_in_at is not null or a.opens > 0) as been_in
      from public.outreach_owner_activity() a
     where a.venue_id in (select np.id from np)
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'venue_id', n.id, 'name', n.name, 'type', n.type,
           'city', n.city, 'country', n.country, 'slug', n.webflow_slug,
           'website', n.website, 'live_at', n.live_at,
           -- the line to write from: one with an address first
           'contact_id', c.id, 'email', c.email, 'stage', c.stage,
           'address_looked', n.contact_checked_at is not null,
           'written_at', (select max(c2.last_out_at) from public.space_contacts c2
                           where c2.venue_id = n.id),
           'looked_at', case when lk.last_at >= n.live_at then lk.last_at end,
           'claimed_at', cl.at, 'claim_status', cl.status,
           'been_in', case when cl.at is not null then coalesce(ac.been_in, false) end,
           -- an owner put on by us, with no claim of their own: not a
           -- cold hello, and left out of the counts
           'ours', n.has_owner and cl.at is null))
           order by n.live_at desc, n.name), '[]'::jsonb)
    into out
    from np n
    left join lateral (
           select c.id, c.email, c.stage
             from public.space_contacts c
            where c.venue_id = n.id
            order by c.is_test, (c.email is null), c.created_at
            limit 1) c on true
    left join looks lk on lk.venue_id = n.id
    left join lateral (
           select min(k.created_at) as at,
                  (array_agg(k.status order by k.created_at desc))[1] as status
             from public.listing_claims k
            where k.venue_id = n.id
              and k.status in ('free_pending', 'awaiting_approval', 'paid', 'free')) cl on true
    left join act ac on ac.venue_id = n.id;
  return out;
end $$;
revoke all on function public.admin_new_pages() from public, anon;
grant execute on function public.admin_new_pages() to authenticated;

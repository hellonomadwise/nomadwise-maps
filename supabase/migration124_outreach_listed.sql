-- ============================================================
-- Migration 124: the spaces already listed, in Outreach.
-- (Applied automatically by the build; nothing to paste.)
--
-- Outreach held only the spaces that wrote to us. The spaces already
-- on nomadwise.io that nobody has claimed are the other half (group B
-- in the framework), and they are in our own database already, so
-- nothing needs typing or pasting:
--   * admin_outreach_add_listed() makes a contact for every unclaimed
--     space on the site that has none, with the address we know when
--     we know one;
--   * when the website sync finds a contact address on a space's own
--     website (venues.contact_emails), the space's contact takes it;
--   * the list and its counts can be narrowed to one group: wrote to
--     us, listed, or prospects. Contacts with an address come first.
-- Bringing spaces in sends nothing. Whether and how listed spaces are
-- invited is Leonie's decision.
-- ============================================================

-- 'wrote' | 'listed' | 'prospect' from where a contact came from.
create or replace function public.outreach_group(p_source text)
returns text language sql immutable as $$
  select case p_source when 'listing' then 'listed'
                       when 'prospect' then 'prospect'
                       else 'wrote' end;
$$;

-- Every unclaimed space on the site that has no contact yet.
create or replace function public.admin_outreach_add_listed()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n       integer;
  n_email integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  with cand as (
    select v.id, v.name, v.type, v.city, v.country, v.website, v.instagram,
           (select lower(trim(x)) from unnest(coalesce(v.contact_emails, '{}')) x
             where position('@' in x) > 1 limit 1) as email
      from public.venues v
     where v.webflow_cms_id is not null
       and coalesce(v.website_status, '') <> 'retired'
       and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
       and coalesce(trim(v.listing_owner_email), '') = ''
       and coalesce(v.listing_tier, 'free') <> 'verified'
       and not exists (select 1 from public.space_contacts c where c.venue_id = v.id)
  ), ranked as (
    select cand.*,
           row_number() over (partition by cand.email order by cand.name) as rn
      from cand
  ), ins as (
    insert into public.space_contacts
      (venue_id, space_name, kind, city, country, email, website, instagram, source, stage)
    select r.id, r.name, r.type, nullif(trim(r.city), ''), nullif(trim(r.country), ''),
           -- One contact per address: a chain's shared address goes to
           -- its first space, and never to one we already hold.
           case when r.email is not null and r.rn = 1
                 and not exists (select 1 from public.space_contacts c where lower(c.email) = r.email)
                then r.email end,
           nullif(trim(r.website), ''), nullif(trim(r.instagram), ''), 'listing', 'new'
      from ranked r
    returning email
  )
  select count(*), count(email) into n, n_email from ins;
  return jsonb_build_object('added', n, 'with_email', n_email);
end $$;
revoke all on function public.admin_outreach_add_listed() from public, anon;
grant execute on function public.admin_outreach_add_listed() to authenticated;

-- An address found on a space's own website reaches its contact.
create or replace function public.outreach_email_from_venue()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  em text;
begin
  select lower(trim(x)) into em
    from unnest(coalesce(new.contact_emails, '{}')) x
   where position('@' in x) > 1
     and not exists (select 1 from public.space_contacts c where lower(c.email) = lower(trim(x)))
   limit 1;
  if em is not null then
    update public.space_contacts c
       set email = em
     where c.id = (select c2.id from public.space_contacts c2
                    where c2.venue_id = new.id and c2.email is null
                    order by c2.created_at limit 1);
  end if;
  return new;
end $$;
drop trigger if exists outreach_email_from_venue on public.venues;
create trigger outreach_email_from_venue
  after update of contact_emails on public.venues
  for each row
  when (new.contact_emails is distinct from old.contact_emails)
  execute function public.outreach_email_from_venue();

-- Counts for the tabs, for one group or all. Keys starting with an
-- underscore are the group sizes and how many have no address.
drop function if exists public.admin_outreach_counts();
create or replace function public.admin_outreach_counts(p_group text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select stage, count(*) n from public.space_contacts
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

-- The list: one stage (or all), one group (or all), optional search.
-- Contacts with an address first, then newest activity.
drop function if exists public.admin_outreach_list(text, text, integer);
create or replace function public.admin_outreach_list(
  p_stage text default null, p_q text default null, p_limit integer default 200,
  p_group text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := lower(trim(coalesce(p_q, '')));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.no_email, x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at,
               (c.email is null) as no_email,
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) as sort_at,
               v.name as venue_name, v.city as venue_city, v.country as venue_country,
               v.webflow_slug, (v.webflow_cms_id is not null) as on_site,
               v.listing_tier, v.listing_owner_email,
               (select m.body from public.outreach_messages m
                 where m.contact_id = c.id and m.direction = 'in'
                 order by m.at desc limit 1) as last_in,
               (select count(*) from public.outreach_messages m where m.contact_id = c.id) as message_count
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
         where (p_stage is null or p_stage = '' or c.stage = p_stage)
           and (coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
           and (q = '' or lower(coalesce(c.space_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.email, '')) like '%' || q || '%'
                       or lower(coalesce(c.person_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.city, '')) like '%' || q || '%'
                       or lower(coalesce(c.country, '')) like '%' || q || '%'
                       or lower(coalesce(v.name, '')) like '%' || q || '%')
         order by no_email, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text) to authenticated;

-- For the website sync: spaces whose contact has no address yet and
-- whose own website has not been read. A few at a time.
create or replace function public.outreach_venues_to_check(p_limit integer default 10)
returns table (id uuid, name text, website text, contact_emails text[])
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.website, v.contact_emails
    from public.venues v
   where v.contact_checked_at is null
     and coalesce(trim(v.website), '') <> ''
     and exists (select 1 from public.space_contacts c
                  where c.venue_id = v.id and c.email is null)
   order by v.name
   limit greatest(0, least(coalesce(p_limit, 10), 50));
$$;
revoke all on function public.outreach_venues_to_check(integer) from public, anon, authenticated;
grant execute on function public.outreach_venues_to_check(integer) to service_role;


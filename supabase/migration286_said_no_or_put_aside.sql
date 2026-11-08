-- ============================================================
-- Migration 286: "Not now or declined" split into what really happened.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 8 Nov 2026, on Ohana showing "Not now, declined or asked us
-- not to write": "I can't find any proof that they ever said not to
-- write or declined ... I want to know which one said no, which ones
-- said that declined, and which ones just didn't respond".
--
-- In Outreach, "Not now" is "Put aside": one of us parked the card
-- (Ohana: 10 Oct 2026, never written to). That is our choice, not their
-- answer. Now, in Spaces and Claim plan:
--   put_aside         Put aside by us (Outreach "Not now"): not their answer
--   declined          Said no (they told us)
--   unsubscribed      Unsubscribed: asked us not to write
--   bounced           Email bounced
--   not_for_outreach  Set aside as not a fit or other business
-- and "Written to, waiting" stays the one for no answer yet.
-- In Claim plan, put_aside is its own step; stepped_off is now only
-- said no, unsubscribed, bounced or not for outreach.
-- ============================================================

create or replace function public.space_crm_rows(p_venue uuid default null)
returns setof jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with v as (
    select * from public.venues
     where coalesce(webflow_slug, '') <> '' and website_retired_at is null
       and (p_venue is null or id = p_venue)
  ), line as (
    select distinct on (c.venue_id) c.*
      from public.space_contacts c
     where c.venue_id in (select id from v) and not coalesce(c.is_test, false)
     order by c.venue_id, (c.email is not null) desc, c.last_out_at desc nulls last, c.created_at
  ), views as (
    select venue_id, sum(n)::int n from public.page_counts
     where kind = 'view' and day > current_date - 90 and venue_id in (select id from v)
     group by 1
  ), seen as (
    select venue_id, max(last_at) last_at from public.owner_visits
     where venue_id in (select id from v) group by 1
  ), looks as (
    select venue_id, max(last_at) last_at from public.claim_look_lines() group by 1
  )
  select jsonb_build_object(
    'id', v.id, 'name', v.name, 'kind', v.type, 'slug', v.webflow_slug,
    'city', coalesce(nullif(v.city, ''), c.city), 'country', coalesce(nullif(v.country, ''), c.country),
    'views', coalesce(w.n, 0),
    'plan', case when coalesce(v.listing_tier, 'free') = 'verified' then 'premium' else 'free' end,
    'owner_email', nullif(btrim(v.listing_owner_email), ''), 'owner_name', v.listing_owner_name,
    'owner_seen_at', s.last_at,
    'contact_id', c.id, 'stage', c.stage, 'stage_at', c.stage_at,
    'written_at', c.last_out_at, 'replied_at', c.last_in_at,
    'unsubscribed_at', c.unsubscribed_at, 'aside_reason', c.aside_reason,
    'assigned_to', c.assigned_to,
    'email', c.email,
    'phone', coalesce(nullif(btrim(c.phone), ''), nullif(btrim(v.contact_whatsapp), '')),
    'instagram', coalesce(nullif(c.instagram, ''), nullif(v.instagram, ''), nullif(v.contact_instagram, '')),
    'facebook', coalesce(nullif(v.contact_facebook, ''),
                         case when v.website ~* '(facebook\.com|fb\.com)' then v.website end),
    'form', nullif(v.contact_form_url, ''),
    'website', v.website,
    'looked_at', k.last_at,
    'status', case
      when v.business_status = 'CLOSED_PERMANENTLY' then 'closed'
      when coalesce(btrim(v.listing_owner_email), '') <> '' then
        case when s.last_at is null then 'claimed_never'
             when s.last_at > now() - interval '30 days' then 'claimed_active'
             else 'claimed_dormant' end
      when coalesce(v.listing_tier, 'free') = 'verified' then 'ours'
      when c.stage = 'replied' then 'replied'
      when c.stage = 'unsubscribed' or c.unsubscribed_at is not null then 'unsubscribed'
      when c.stage = 'declined' then 'declined'
      when c.stage = 'bounced' then 'bounced'
      when c.aside_at is not null then 'not_for_outreach'
      when c.stage = 'not_now' then 'put_aside'
      when k.last_at is not null then 'looked'
      when c.last_out_at is not null then 'written'
      when c.email is not null or coalesce(btrim(c.phone), '') <> ''
           or coalesce(v.contact_whatsapp, v.contact_form_url, v.contact_facebook, v.contact_instagram,
                       nullif(c.instagram, ''), nullif(v.instagram, '')) is not null
           or coalesce(btrim(v.website), '') <> ''
        then 'not_reached'
      else 'no_way_in'
    end)
  from v
  left join line c on c.venue_id = v.id
  left join views w on w.venue_id = v.id
  left join seen s on s.venue_id = v.id
  left join looks k on k.venue_id = v.id;
$$;
revoke all on function public.space_crm_rows(uuid) from public, anon, authenticated;

create or replace function public.admin_claim_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_looked uuid[] := '{}';
  rows jsonb;
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  begin
    select coalesce(array_agg(distinct l.venue_id), '{}') into v_looked from public.claim_look_lines() l;
  exception when others then
    v_looked := '{}';
  end;

  with live as (
    select v.* from public.venues v
     where coalesce(v.webflow_slug, '') <> '' and v.website_retired_at is null
       and coalesce(btrim(v.listing_owner_email), '') = ''
       and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
  ), line as (
    select distinct on (c.venue_id) c.*
      from public.space_contacts c
     where c.venue_id is not null and not coalesce(c.is_test, false)
     order by c.venue_id, (c.email is not null) desc, c.last_out_at desc nulls last, c.created_at
  ), views as (
    select venue_id, sum(n)::int n from public.page_counts
     where kind = 'view' and day > current_date - 90 group by 1
  ), x as (
    select l.id venue_id, l.name, l.webflow_slug, c.id contact_id,
           l.type kind, coalesce(nullif(l.city, ''), c.city) city,
           coalesce(nullif(l.country, ''), c.country) country,
           coalesce(w.n, 0) views, c.email,
           coalesce(nullif(btrim(c.phone), ''), nullif(btrim(l.contact_whatsapp), '')) phone,
           coalesce(nullif(c.instagram, ''), nullif(l.instagram, ''), nullif(l.contact_instagram, ''),
                    case when l.website ~* 'instagram\.com' then l.website end) instagram,
           coalesce(nullif(l.contact_facebook, ''),
                    case when l.website ~* '(facebook\.com|fb\.com)' then l.website end) facebook,
           nullif(l.contact_form_url, '') form,
           l.website, c.stage, c.last_out_at, c.notes,
           (c.notes ilike '%Round 1 (8 Nov)%') round1,
           (select c2.space_name from public.space_contacts c2
             where c2.venue_id is distinct from l.id and c2.email is not null
               and lower(c2.email) = any (select lower(e) from unnest(coalesce(l.contact_emails, '{}')) e)
             order by c2.last_out_at desc nulls last limit 1) covered_by,
           (select c2.last_out_at is not null from public.space_contacts c2
             where c2.venue_id is distinct from l.id and c2.email is not null
               and lower(c2.email) = any (select lower(e) from unnest(coalesce(l.contact_emails, '{}')) e)
             order by c2.last_out_at desc nulls last limit 1) covered_sent,
           (l.id = any (v_looked)) looked,
           c.follow_up_on, c.unsubscribed_at, c.aside_at
      from live l
      left join line c on c.venue_id = l.id
      left join views w on w.venue_id = l.id
  ), y as (
    select x.*,
      -- reached: written to, or covered by an email already sent to the
      -- same company
      (last_out_at is not null or (covered_by is not null and coalesce(covered_sent, false))) reached,
      case
        when stage = 'replied' then 'replied'
        when stage in ('declined', 'unsubscribed', 'bounced')
             or unsubscribed_at is not null or aside_at is not null then 'stepped_off'
        when stage = 'not_now' then 'put_aside'
        when looked then 'looked'
        when public.outreach_follow_up_due(stage, follow_up_on, last_out_at) then 'follow_up'
        when last_out_at is not null then 'waiting'
        when email is not null and (notes ilike '%check first%' or email ilike 'press@%'
             or email ilike '%@www.%' or email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$')
             then 'check'
        when email is not null then 'email'
        when covered_by is not null then 'covered'
        when phone is not null then 'whatsapp'
        when form is not null then 'form'
        when instagram is not null then 'instagram'
        when facebook is not null then 'facebook'
        when coalesce(website, '') <> '' and website !~* '(facebook\.com|fb\.com|linktr\.ee|instagram\.com)' then 'find'
        else 'nothing'
      end action
    from x
  )
  select jsonb_build_object(
    'unclaimed', (select count(*) from y),
    'closed', (select count(*) from public.venues v
                where coalesce(v.webflow_slug, '') <> '' and v.website_retired_at is null
                  and coalesce(btrim(v.listing_owner_email), '') = ''
                  and v.business_status = 'CLOSED_PERMANENTLY'),
    'claimed', (select count(*) from public.venues v
                 where coalesce(v.webflow_slug, '') <> '' and coalesce(btrim(v.listing_owner_email), '') <> ''),
    'written', (select count(*) from y where last_out_at is not null),
    'looked', (select count(*) from y where looked),
    'replied', (select count(*) from y where stage = 'replied'),
    'round1', (select count(*) from y where round1),
    'round1_sent', (select count(*) from y where round1 and last_out_at is not null),
    'reached', (select count(*) from y where reached),
    -- the claimed pages, for the split by type and country
    'claimed_list', (select coalesce(jsonb_agg(jsonb_build_object('kind', v.type, 'country', v.country)), '[]'::jsonb)
                       from public.venues v
                      where coalesce(v.webflow_slug, '') <> '' and coalesce(btrim(v.listing_owner_email), '') <> ''),
    'counts', (select jsonb_object_agg(action, n) from (select action, count(*) n from y group by 1) q),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
               'venue_id', venue_id, 'contact_id', contact_id, 'name', name, 'slug', webflow_slug,
               'kind', kind, 'city', city, 'country', country, 'views', views,
               'email', email, 'phone', phone, 'instagram', instagram, 'website', website,
               'facebook', facebook, 'form', form,
               'covered_by', covered_by, 'covered_sent', covered_sent,
               'stage', stage, 'last_out_at', last_out_at, 'round1', round1, 'action', action,
               'reached', reached)
             order by views desc, name), '[]'::jsonb) from y)
  ) into rows;
  return rows;
end $$;

revoke all on function public.admin_claim_plan() from public, anon;
grant execute on function public.admin_claim_plan() to authenticated;

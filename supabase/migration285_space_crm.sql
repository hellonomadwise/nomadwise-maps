-- ============================================================
-- Migration 285: Spaces, one overview per space (a small CRM).
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 8 Nov 2026: "a crm style where I can easily pull up the
-- overview on a space as quickly and easy as possible, and have a full
-- overview, and status on where they are at in terms of if claimed,
-- not reached out to yet, claimed but dormant, and all the info
-- available".
--
--   space_crm_rows(venue)     one row per live page with its status
--                             (internal, used by the two below)
--   admin_spaces()            every live page with its status, for the
--                             Spaces list and its search
--   admin_space_profile(id)   everything about one space: status,
--                             plan, numbers, ways in, Owner account use,
--                             what they asked for, Outreach and its
--                             messages, claims and drafts
--
-- Status, one per space (first that applies):
--   closed           Google lists it as closed for good
--   claimed_active   claimed, in their Owner account in the last 30 days
--   claimed_dormant  claimed, not in their Owner account for 30+ days
--   claimed_never    claimed, never in their Owner account
--   ours             Premium set up by us, not claimed
--   replied          they wrote back
--   not_now          not now, declined, unsubscribed or set aside
--   looked           someone opened their claim page
--   written          written to, no answer yet
--   not_reached      a way in (email, WhatsApp, form, Instagram,
--                    Facebook, or a website to find one on), nobody has
--                    written yet
--   no_way_in        no way in yet
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
    'contact_id', c.id, 'stage', c.stage, 'written_at', c.last_out_at, 'replied_at', c.last_in_at,
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
      when c.stage in ('not_now', 'declined', 'unsubscribed', 'bounced')
           or c.unsubscribed_at is not null or c.aside_at is not null then 'not_now'
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

create or replace function public.admin_spaces()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  return (select jsonb_build_object(
            'rows', coalesce(jsonb_agg(r order by (r->>'views')::int desc, r->>'name'), '[]'::jsonb))
            from public.space_crm_rows(null) r);
end $$;
revoke all on function public.admin_spaces() from public, anon;
grant execute on function public.admin_spaces() to authenticated;

create or replace function public.admin_space_profile(p_venue uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  base jsonb;
  v public.venues%rowtype;
  g_end date;
  em text;
begin
  if not public.is_admin() then raise exception 'Team only.'; end if;
  select * into v from public.venues where id = p_venue;
  if not found then raise exception 'Space not found.'; end if;
  select r into base from public.space_crm_rows(p_venue) r limit 1;
  select max(day) into g_end from public.page_google_days;
  em := lower(btrim(coalesce(v.listing_owner_email, '')));

  return coalesce(base, jsonb_build_object('id', v.id, 'name', v.name, 'status', 'not_live'))
    || jsonb_build_object(
      'live', base is not null,
      'neighbourhood', v.neighbourhood,
      'rating', v.google_rating_snapshot, 'reviews', v.google_reviews_snapshot,
      'listed_at', coalesce(v.new_page_live_at, v.website_approved_at, v.created_at),
      'paid_at', v.listing_paid_at, 'renews_at', v.listing_renews_at,
      'paying', v.stripe_subscription_id is not null,
      'enquiry_email', v.listing_enquiry_email,
      'contact_emails', v.contact_emails,
      'closed_until', v.owner_reopens_on,
      'numbers', jsonb_build_object(
        'views_30', (select coalesce(sum(n), 0) from public.page_counts
                      where venue_id = p_venue and kind = 'view' and day > current_date - 30),
        'views_90', (select coalesce(sum(n), 0) from public.page_counts
                      where venue_id = p_venue and kind = 'view' and day > current_date - 90),
        'google_30', (select coalesce(sum(impressions), 0) from public.page_google_days
                       where venue_id = p_venue and g_end is not null
                         and day > g_end - 30 and day <= g_end),
        'requests_30', (select count(*) from public.enquiries
                         where venue_id = p_venue and created_at > now() - interval '30 days'),
        'requests_all', (select count(*) from public.enquiries where venue_id = p_venue)),
      'page', (select jsonb_build_object('done', s.done, 'total', s.total)
                 from public.owner_page_state s where s.venue_id = p_venue),
      'claims', (select coalesce(jsonb_agg(jsonb_build_object(
                    'at', c.created_at, 'approved_at', c.approved_at, 'plan', c.plan,
                    'owner_name', c.owner_name, 'owner_email', c.owner_email,
                    'owner_role', c.owner_role) order by c.created_at desc), '[]'::jsonb)
                   from public.listing_claims c where c.venue_id = p_venue),
      'draft', (select jsonb_build_object('status', d.status, 'at', d.updated_at,
                                          'submitted_at', d.submitted_at, 'note', d.review_note)
                  from public.owner_drafts d where d.venue_id = p_venue
                 order by d.updated_at desc limit 1),
      'owner', case when em = '' then null else jsonb_build_object(
        'days_in', (select count(*) from public.owner_visits where venue_id = p_venue),
        'opens', (select coalesce(sum(opens), 0) from public.owner_visits where venue_id = p_venue),
        'first_in', (select min(first_at) from public.owner_visits where venue_id = p_venue),
        'last_in', (select max(last_at) from public.owner_visits where venue_id = p_venue),
        'visits_30', (select count(*) from public.owner_sessions
                       where owner_email = em and not team and started_at > now() - interval '30 days'),
        'saves_30', (select count(*) from public.owner_activity
                      where owner_email = em and kind = 'edit_save' and at > now() - interval '30 days'),
        'recent', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
                     select jsonb_build_object('at', a.at, 'kind', a.kind, 'detail', a.detail) x
                       from public.owner_activity a
                       join public.owner_sessions s on s.id = a.session_id and not s.team
                      where a.owner_email = em
                      order by a.at desc limit 15) q)) end,
      'wishes', (select coalesce(jsonb_agg(jsonb_build_object(
                    'at', w.created_at, 'text', w.text, 'status', w.status, 'reply', w.reply)
                    order by w.created_at desc), '[]'::jsonb)
                   from public.owner_wishes w where w.venue_id = p_venue and not w.team),
      'contacts', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', c.id, 'email', c.email, 'phone', c.phone, 'person', c.person_name,
                      'stage', c.stage, 'stage_at', c.stage_at, 'written_at', c.last_out_at,
                      'replied_at', c.last_in_at, 'follow_up_on', c.follow_up_on,
                      'assigned_to', c.assigned_to, 'notes', c.notes, 'topic', c.topic,
                      'source', c.source) order by c.created_at), '[]'::jsonb)
                     from public.space_contacts c where c.venue_id = p_venue and not coalesce(c.is_test, false)),
      'messages', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
                     select jsonb_build_object('at', m.at, 'direction', m.direction,
                              'subject', m.subject, 'body', left(m.body, 3000), 'by', m.sent_by) x
                       from public.outreach_messages m
                       join public.space_contacts c on c.id = m.contact_id
                      where c.venue_id = p_venue
                      order by m.at desc limit 40) q));
end $$;
revoke all on function public.admin_space_profile(uuid) from public, anon;
grant execute on function public.admin_space_profile(uuid) to authenticated;

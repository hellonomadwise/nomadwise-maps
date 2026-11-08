-- ============================================================
-- Migration 284: every unclaimed space and what to do next.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 8 Nov 2026: "I just want to know what action to take with
-- each space, and to make sure it's recorded, so we can monitor."
--
-- admin_claim_plan() gives one row per page live on nomadwise.io that
-- nobody has claimed, with the one next step for it, worked out from
-- what we already know (first that applies):
--   replied      they wrote back: answer them
--   stepped_off  not now, declined, unsubscribed, bounced or set aside
--   looked       someone opened their claim page: ask about it
--   follow_up    written to, no answer, the follow-up date has come
--   waiting      written to, waiting for an answer
--   check        an email, but it looks wrong (press@, typo, marked
--                "Check first"): check it before writing
--   email        an email address: send the email
--   covered      no address of its own, but the same company's email is
--                on another space's card: one email covers both
--   whatsapp     a WhatsApp or phone number: send a WhatsApp
--   form         a contact form on their website: send it there
--   instagram    an Instagram account: send a message there
--   facebook     a Facebook page: send a message there
--   find         a website but no address found: find one
--   nothing      no way in yet
-- Everything is recorded in Outreach as before ("I sent it", "Add an
-- address", "Log what they wrote"), so each row moves on by itself.
--
-- Also: live pages with no Outreach card get one where Outreach would
-- take them (1 on 8 Nov). Pages Google lists as closed for good are
-- left out of the plan and counted apart (47 on 8 Nov: for Quality).
--
-- Jonathan, 8 Nov: "Some might be a case of messaging on WhatsApp or
-- Facebook", "Or if they have a contact us form on their website".
--   - The website reader (scripts/webflow_enquiries.py) now also keeps
--     the WhatsApp number, Facebook page, Instagram account and contact
--     form it finds on a space's own site (venues.contact_*), and reads
--     again the sites where it found no address.
--   - A message sent through a contact form is recorded like WhatsApp,
--     Instagram and Facebook (admin_outreach_log_message, 'form').
--   - invite_listed_wa: the short message for WhatsApp, Instagram and
--     Facebook to a space listed a while (invite_new_page_wa says "we
--     have added", which is wrong for those).

alter table public.venues
  add column if not exists contact_whatsapp text,
  add column if not exists contact_facebook text,
  add column if not exists contact_instagram text,
  add column if not exists contact_form_url text;

-- Read again: live, unclaimed sites of their own where no address was
-- found, so the reader can pick up the other ways in.
update public.venues v
   set contact_checked_at = null
 where coalesce(v.webflow_slug, '') <> '' and v.website_retired_at is null
   and coalesce(btrim(v.listing_owner_email), '') = ''
   and coalesce(v.business_status, '') <> 'CLOSED_PERMANENTLY'
   and coalesce(btrim(v.website), '') <> ''
   and v.website !~* '(instagram\.com|facebook\.com|fb\.com|linktr\.ee|wa\.me)'
   and coalesce(array_length(v.contact_emails, 1), 0) = 0
   and v.contact_checked_at is not null
   and v.contact_form_url is null and v.contact_whatsapp is null and v.contact_facebook is null;

insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('invite_listed_wa', 'First contact: listed a while, now a members area (WhatsApp, Instagram, Facebook)', 'WhatsApp',
 'Hi, this is Jonathan from Nomadwise. {space} has a page on nomadwise.io, where remote workers and digital nomads look for good places to work from: {page_link}

You can now claim it for free and manage it yourself, and update your opening hours, photos, description and prices whenever it suits you: {claim_link}

{signoff}', 'outbound', 47)
on conflict (key) do nothing;

-- As migration 160, with the contact form beside WhatsApp, Instagram
-- and Facebook.
create or replace function public.admin_outreach_log_message(
  p_id uuid, p_body text, p_channel text, p_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c     public.space_contacts%rowtype;
  who   text;
  label text := case lower(coalesce(p_channel, ''))
                  when 'whatsapp' then 'WhatsApp'
                  when 'instagram' then 'Instagram'
                  when 'facebook' then 'Facebook'
                  when 'form' then 'Contact form'
                end;
  -- when the page was opened with the message (at most six hours ago)
  sent  timestamptz := greatest(now() - interval '6 hours',
                                least(now(), coalesce(p_at, now())));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if label is null then
    raise exception 'Unknown channel: %', coalesce(p_channel, '(none)');
  end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by, at)
  values (c.id, 'out', 'claim_looked_wa', label, left(coalesce(p_body, ''), 4000),
          who || ' (' || label || ')', sent);
  update public.space_contacts
     set last_out_at = sent,
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_outreach_log_message(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.admin_outreach_log_message(uuid, text, text, timestamptz) to authenticated;
-- ============================================================

do $$
declare n int := 0;
begin
  perform public.outreach_line_for_venue(v.id)
     from public.venues v
    where coalesce(v.webflow_slug, '') <> '' and v.website_retired_at is null
      and coalesce(btrim(v.listing_owner_email), '') = ''
      and not exists (select 1 from public.space_contacts c where c.venue_id = v.id);
exception when others then
  raise notice 'outreach lines: %', sqlerrm;
end $$;

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
        when stage in ('not_now', 'declined', 'unsubscribed', 'bounced')
             or unsubscribed_at is not null or aside_at is not null then 'stepped_off'
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

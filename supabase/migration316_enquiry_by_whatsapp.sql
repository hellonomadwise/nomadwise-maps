-- ============================================================
-- Migration 316: pass an enquiry on by WhatsApp
-- ============================================================
-- Jonathan, 11 Nov 2026, on Coworking Space H24 (Koh Phangan): no
-- email anywhere (its website is an Instagram page), so "Check the
-- emails" stayed grey. He found their WhatsApp number and saved it in
-- the pass-on window: "need to have a button that provides a draft
-- message to whatsapp".
--
-- * the pass-on list carries the number kept on the space in Outreach
--   (so the box is filled in next time)
-- * enquiry_whatsapp_text(): the enquiry as a WhatsApp message. The
--   space cannot "just reply" to reach the nomad as it can by email,
--   so the nomad's name, email and phone are in the message.
-- * admin_enquiry_whatsapp_draft(): that draft, for the window
-- * admin_enquiry_passed_whatsapp(): called once he says he sent it.
--   The enquiry is passed on ("WhatsApp +66 ..."), the message is
--   kept on the space in Outreach, and the nomad is told (the usual
--   email, saying WhatsApp and "asked them to reply to you directly"
--   in place of "their reply will come straight to your email").
-- Nothing is sent to the space by us: WhatsApp opens with the words
-- and he presses send there.
-- ============================================================

select public.pm_patch_fn('public.admin_enquiries_to_pass_on()',
$a$'contact_checked', v.contact_checked_at is not null,$a$,
$a$'contact_checked', v.contact_checked_at is not null,
               'contact_phone', (select c.phone from public.space_contacts c
                                  where c.venue_id = v.id
                                    and nullif(btrim(coalesce(c.phone, '')), '') is not null
                                  order by coalesce(c.is_test, false), c.updated_at desc nulls last
                                  limit 1),$a$,
$m$'contact_phone'$m$);

create or replace function public.enquiry_whatsapp_text(p_id uuid)
returns text
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  first text;
  msg   text;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;
  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(btrim(e.name), ' ', 1), ''), 'Someone');
  msg := nullif(btrim(regexp_replace(coalesce(e.message, ''),
           '\s*\(Sent from the price list on the page\.\)\s*$', '')), '');

  return
    'Hi, this is Jonathan from Nomadwise. ' || v.name || ' is listed on our site'
    || coalesce(': ' || page, '.') || E'\n\n'
    || 'A remote worker found you there and sent this enquiry for you:' || E'\n\n'
    || coalesce('"' || msg || '"' || E'\n\n', '')
    || 'Name: ' || e.name || E'\n'
    || 'Email: ' || e.email || E'\n'
    || coalesce('Phone: ' || nullif(btrim(coalesce(e.phone, '')), '') || E'\n', '')
    || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                   when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                   when 'event' then 'Interested in: a meeting or event' || E'\n'
                   else '' end
    || coalesce('Dates: ' || nullif(btrim(coalesce(e.dates, '')), '') || E'\n', '')
    || coalesce('People: ' || e.people::text || E'\n', '')
    || E'\n'
    || 'Could you reply to ' || coalesce(first, 'them') || ' directly? Thank you.'
    || case when v.listing_tier is distinct from 'verified'
                 and coalesce(btrim(v.listing_owner_email), '') = ''
            then E'\n\n' || 'You can also look after your page yourself, for free: '
                 || 'https://nomadmaps.io/?claim='
                 || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'))
            else '' end;
end $function$;

revoke all on function public.enquiry_whatsapp_text(uuid) from public, anon, authenticated;

create or replace function public.admin_enquiry_whatsapp_draft(p_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object('text', public.enquiry_whatsapp_text(p_id));
end $function$;

revoke all on function public.admin_enquiry_whatsapp_draft(uuid) from public, anon;
grant execute on function public.admin_enquiry_whatsapp_draft(uuid) to authenticated;

create or replace function public.admin_enquiry_passed_whatsapp(
  p_id uuid, p_phone text, p_body text default null, p_tell_nomad boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  e    public.enquiries%rowtype;
  v    public.venues%rowtype;
  ph   text := nullif(btrim(regexp_replace(coalesce(p_phone, ''), '[^0-9+() -]', '', 'g')), '');
  cid  uuid;
  who  text;
  nd   jsonb;
  told boolean := false;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if ph is null or length(regexp_replace(ph, '[^0-9]', '', 'g')) < 8 then
    raise exception 'That does not look like a phone number.';
  end if;
  select * into e from public.enquiries where id = p_id for update;
  if not found then raise exception 'Enquiry not found.'; end if;
  if e.status <> 'waiting' then
    raise exception 'This enquiry has already been dealt with.';
  end if;
  if e.venue_id is null then
    raise exception 'Choose the space first.';
  end if;
  select * into v from public.venues where id = e.venue_id;

  update public.enquiries
     set status = 'passed', passed_to = left('WhatsApp ' || ph, 200), passed_at = now(),
         send_error = null
   where id = p_id;

  -- The number and the message, on the space in Outreach. Never in
  -- the way of the enquiry itself.
  begin
    cid := public.outreach_remember_contact(v.id, null, ph);
    if cid is not null then
      who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
      insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by, at)
      values (cid, 'out', 'enquiry_passed_wa', 'WhatsApp: an enquiry passed on',
              left(coalesce(nullif(btrim(p_body), ''), public.enquiry_whatsapp_text(p_id), ''), 4000),
              who || ' (WhatsApp)', now());
      update public.space_contacts
         set last_out_at = now(),
             stage = case when stage in ('new', 'not_now') then 'contacted' else stage end
       where id = cid;
    end if;
  exception when others then
    null;
  end;

  if p_tell_nomad then
    nd := public.enquiry_nomad_email(array[p_id]);
    -- The same email as usual, in plain words (no template): by
    -- WhatsApp the space's reply does not come "straight to your
    -- email address" by itself.
    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io', nd ->> 'subject',
      replace(nd ->> 'body',
              ', and their reply will come straight to your email address.',
              ' by WhatsApp, and asked them to reply to you directly.'),
      'enquiry_passed_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
    told := true;
  end if;

  return jsonb_build_object('status', 'passed', 'to', 'WhatsApp ' || ph, 'told', told);
end $function$;

revoke all on function public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean) from public, anon;
grant execute on function public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean) to authenticated;

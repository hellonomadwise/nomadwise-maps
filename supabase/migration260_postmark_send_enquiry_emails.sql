-- ============================================================
-- Migration 260: enquiry emails can go out through the Postmark templates.
-- (Applied automatically by the build; nothing to paste.)
--
-- Same idea as migration 259, for emails 14-19 (enquiry to a space on a
-- free enquiry, request sent / received for the nomad, enquiry waiting
-- for Premium, enquiry to a Premium space, did you find a place?).
--
--  * The enquiry email builders (enquiry_space_email, enquiry_held_email,
--    enquiry_received_email, enquiry_nomad_email) now also give back the
--    template's alias and model, from the same facts as their text.
--  * The senders hand that model over with pm_set_model; send_enquiry_mail
--    takes it, like send_owner_email. send_enquiry (Premium, straight to
--    the space's enquiry address) uses its template when it is on.
--  * send_enquiry_mail now keeps what it sent (payload) with its row in
--    owner_emails, so pm_check_sent can check it and a failed send is
--    tried again like the owner emails.
--  * Emails written or edited by a founder in the control centre (pass on,
--    tell the nomad, close) keep going out as written.
-- Way back for any email: update email_templates set live = false where alias = '...'.
-- ============================================================

-- ---------- the sender used by the enquiry emails ----------
select public.pm_patch_fn('public.send_enquiry_mail(text,text,text,text,text,text,uuid,text)',
$a$  payload jsonb;
begin
  select decrypted_secret into token$a$,
$a$  payload jsonb;
  pmt     record;
  purl    text := 'https://api.postmarkapp.com/email';
begin
  -- the Postmark template for this email, when it is switched on (migration 260)
  select * into pmt from public.pm_take_model(p_kind);
  select decrypted_secret into token$a$,
'pm_take_model');

select public.pm_patch_fn('public.send_enquiry_mail(text,text,text,text,text,text,uuid,text)',
$a$  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,$a$,
$a$  if pmt.alias is not null then
    payload := (payload - 'Subject' - 'TextBody' - 'HtmlBody')
               || jsonb_build_object('TemplateAlias', pmt.alias, 'TemplateModel', pmt.model,
                                     'MessageStream', pmt.stream);
    purl := 'https://api.postmarkapp.com/email/withTemplate';
  end if;
  select net.http_post(
    url := purl,
    body := payload,$a$,
'url := purl');

select public.pm_patch_fn('public.send_enquiry_mail(text,text,text,text,text,text,uuid,text)',
$a$    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, venue_id)
    values (p_kind, p_to, p_subject, p_ref, 'sent', req::text, p_text, p_venue);$a$,
$a$    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, venue_id,
                                     payload, attempts, last_try_at)
    values (p_kind, p_to, p_subject, p_ref, 'sent', req::text, p_text, p_venue, payload, 1, now());$a$,
'p_venue, payload');

-- ---------- builders: the model next to the text ----------
select public.pm_patch_fn('public.enquiry_space_email(uuid)',
$a$  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',$a$,
$a$  return jsonb_build_object(
    'alias', 'enquiry-to-space',
    'model', jsonb_build_object(
      'space_name', v.name, 'subject_prefix', '',
      'page_url', coalesce(page, ''), 'has_page', page is not null, 'no_page_yet', page is null,
      'enquiry_name', e.name, 'enquiry_email', e.email,
      'enquiry_phone', coalesce(nullif(e.phone, ''), ''),
      'enquiry_want', case e.want when 'day_pass' then 'a day pass'
                                  when 'desk_month' then 'a desk for a month or longer'
                                  when 'event' then 'a meeting or event' else '' end,
      'enquiry_dates', coalesce(nullif(e.dates, ''), ''),
      'enquiry_people', coalesce(e.people::text, ''),
      'enquiry_sent', to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY'),
      'message', coalesce(nullif(btrim(e.message), ''), '(No message)'),
      'message_html', public.pm_html_text(coalesce(nullif(btrim(e.message), ''), '(No message)')),
      'enquiry_first', coalesce(first, 'them'),
      'is_released', e.held_at is not null,
      'is_free_slot', e.held_at is null and coalesce(e.free_slot, false),
      'free_used', coalesce(used, 0), 'free_limit', coalesce(lim, 0),
      'premium_url', 'https://nomadmaps.io/?owner&billing',
      'is_premium_no_address', e.held_at is null and not coalesce(e.free_slot, false)
                               and v.listing_tier is not distinct from 'verified',
      'owner_url', 'https://nomadmaps.io/?owner',
      'is_unclaimed', e.held_at is null and not coalesce(e.free_slot, false)
                      and v.listing_tier is distinct from 'verified'
                      and coalesce(trim(v.listing_owner_email), '') = '',
      'claim_url', 'https://nomadmaps.io/?claim=' || coalesce(v.webflow_slug, replace(v.name, ' ', '%20')),
      'is_claimed_free', e.held_at is null and not coalesce(e.free_slot, false)
                         and v.listing_tier is distinct from 'verified'
                         and coalesce(trim(v.listing_owner_email), '') <> '')
  ) || jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',$a$,
'enquiry-to-space');

select public.pm_patch_fn('public.enquiry_held_email(uuid)',
$a$  return jsonb_build_object(
    'to', public.enquiry_address(v.id),$a$,
$a$  return jsonb_build_object(
    'alias', 'enquiry-waiting',
    'model', jsonb_build_object(
      'greeting_name', coalesce(first, v.name || ' team'), 'first_name', coalesce(first, ''),
      'space_name', v.name, 'space_kind', '',
      'asked', coalesce(asked, ''), 'asked_html', public.pm_html_text(coalesce(asked, '')),
      'asked_with_message', asked is not null and coalesce(extra, false),
      'asked_only', asked is not null and not coalesce(extra, false),
      'nothing_asked', asked is null,
      'free_limit', lim, 'premium_url', 'https://nomadmaps.io/?owner&billing',
      'cta_url', 'https://nomadmaps.io/?owner&billing', 'owner_url', 'https://nomadmaps.io/owner',
      'page_url', '', 'has_page', false, 'no_page_yet', true)
  ) || jsonb_build_object(
    'to', public.enquiry_address(v.id),$a$,
'enquiry-waiting');

select public.pm_patch_fn('public.enquiry_received_email(uuid)',
$a$  return jsonb_build_object(
    'to', lower(e.email),$a$,
$a$  return jsonb_build_object(
    'alias', 'enquiry-received-nomad',
    'model', jsonb_build_object(
      'greeting_name', coalesce(first, 'there'), 'subject_prefix', '',
      'space_name', coalesce(vname, ''), 'space_or_the_space', coalesce(vname, 'the space'),
      'message', coalesce(nullif(btrim(regexp_replace(coalesce(e.message, ''),
                   '\s*\(Sent from the price list on the page\.\)\s*$', '')), ''), '(No message)'),
      'message_html', public.pm_html_text(coalesce(nullif(btrim(regexp_replace(coalesce(e.message, ''),
                   '\s*\(Sent from the price list on the page\.\)\s*$', '')), ''), '(No message)')),
      'enquiry_name', e.name, 'enquiry_email', e.email,
      'enquiry_phone', coalesce(nullif(btrim(coalesce(e.phone, '')), ''), ''))
  ) || jsonb_build_object(
    'to', lower(e.email),$a$,
'enquiry-received-nomad');

select public.pm_patch_fn('public.enquiry_nomad_email(uuid[])',
$a$    return jsonb_build_object(
      'to', em,
      'subject', 'Your request has been sent to ' || one,$a$,
$a$    return coalesce((select jsonb_build_object(
      'alias', 'enquiry-sent-nomad',
      'model', jsonb_build_object(
        'greeting_name', coalesce(first, 'there'), 'subject_prefix', '',
        'space_name', one, 'website', coalesce(btrim(site), ''),
        'message', coalesce(nullif(btrim(regexp_replace(coalesce(x.message, ''),
                     '\s*\(Sent from the price list on the page\.\)\s*$', '')), ''), '(No message)'),
        'message_html', public.pm_html_text(coalesce(nullif(btrim(regexp_replace(coalesce(x.message, ''),
                     '\s*\(Sent from the price list on the page\.\)\s*$', '')), ''), '(No message)')),
        'enquiry_name', x.name, 'enquiry_email', x.email,
        'enquiry_phone', coalesce(nullif(btrim(coalesce(x.phone, '')), ''), ''))
      ) from public.enquiries x where x.id = p_ids[1]), '{}'::jsonb) || jsonb_build_object(
      'to', em,
      'subject', 'Your request has been sent to ' || one,$a$,
'''enquiry-sent-nomad'',');

select public.pm_patch_fn('public.enquiry_nomad_email(uuid[])',
$a$  return jsonb_build_object(
    'to', em,
    'subject', 'Your request has been sent to ' || n || ' spaces',$a$,
$a$  return jsonb_build_object(
    'alias', 'enquiry-sent-nomad-many',
    'model', jsonb_build_object(
      'greeting_name', coalesce(first, 'there'), 'subject_prefix', '',
      'space_count', n, 'spaces_text', lines, 'spaces_html', public.pm_html_text(lines),
      'any_website', coalesce(sites, false))
  ) || jsonb_build_object(
    'to', em,
    'subject', 'Your request has been sent to ' || n || ' spaces',$a$,
'enquiry-sent-nomad-many');

-- ---------- senders hand the model over ----------
select public.pm_patch_fn('public.enquiry_send_to_space(uuid,text)',
$a$  perform public.send_enquiry_mail(
    dest, e.email, draft ->> 'subject', draft ->> 'body',$a$,
$a$  begin
    perform public.pm_set_model(p_kind, draft ->> 'alias', draft -> 'model');
  exception when others then null; end;
  perform public.send_enquiry_mail(
    dest, e.email, draft ->> 'subject', draft ->> 'body',$a$,
'draft ->> ''alias''');

select public.pm_patch_fn('public.enquiry_send_to_space(uuid,text)',
$a$    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io', nd ->> 'subject', nd ->> 'body',$a$,
$a$    begin
      perform public.pm_set_model('enquiry_passed_nomad', nd ->> 'alias', nd -> 'model');
    exception when others then null; end;
    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io', nd ->> 'subject', nd ->> 'body',$a$,
'nd ->> ''alias''');

select public.pm_patch_fn('public.enquiry_tell_nomad_now(uuid,boolean,text)',
$a$  perform public.send_enquiry_mail(
    lower(e.email), 'spaces@nomadwise.io',$a$,
$a$  begin
    perform public.pm_set_model(
      case when p_test is not null then 'enquiry_test_nomad'
           when p_sent then 'enquiry_passed_nomad'
           else 'enquiry_received_nomad' end,
      mail ->> 'alias',
      (mail -> 'model') || jsonb_build_object('subject_prefix', coalesce(p_test, '')));
  exception when others then null; end;
  perform public.send_enquiry_mail(
    lower(e.email), 'spaces@nomadwise.io',$a$,
'pm_set_model');

select public.pm_patch_fn('public.enquiry_after_insert()',
$a$      perform public.send_owner_email(
        mail ->> 'to', mail ->> 'subject', mail ->> 'body',
        'enquiry_held', new.id::text,$a$,
$a$      begin
        perform public.pm_set_model('enquiry_held', mail ->> 'alias', mail -> 'model');
      exception when others then null; end;
      perform public.send_owner_email(
        mail ->> 'to', mail ->> 'subject', mail ->> 'body',
        'enquiry_held', new.id::text,$a$,
'pm_set_model');

select public.pm_patch_fn('public.enquiry_followup_send()',
$a$      perform public.send_owner_email(
        r.em,
        'Did you find a place to work?',$a$,
$a$      begin
        perform public.pm_set_model('enquiry_followup', 'enquiry-followup-nomad',
          jsonb_build_object('greeting_name', coalesce(nullif(btrim(coalesce(first, '')), ''), 'there'),
            'space_names', public.enquiry_space_names(r.names),
            'cta_url', 'https://nomadmaps.io/?found=' || tok::text));
      exception when others then null; end;
      perform public.send_owner_email(
        r.em,
        'Did you find a place to work?',$a$,
'pm_set_model');

-- ---------- Premium: straight to the space's enquiry address ----------
select public.pm_patch_fn('public.send_enquiry(uuid)',
$a$  req  bigint;
begin$a$,
$a$  req  bigint;
  purl text := 'https://api.postmarkapp.com/email';
begin$a$,
'purl text');

select public.pm_patch_fn('public.send_enquiry(uuid)',
$a$  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,$a$,
$a$  -- the Postmark template, when it is switched on (migration 260)
  begin
    if exists (select 1 from public.email_templates t where t.alias = 'enquiry-premium-direct' and t.live) then
      payload := (payload - 'Subject' - 'TextBody' - 'HtmlBody') || jsonb_build_object(
        'TemplateAlias', 'enquiry-premium-direct',
        'MessageStream', (select t.stream from public.email_templates t where t.alias = 'enquiry-premium-direct'),
        'TemplateModel', jsonb_build_object(
          'for_spaces', true, 'preview', 'New enquiry for ' || v.name || '.',
          'space_name', v.name, 'enquiry_name', e.name, 'enquiry_email', e.email,
          'enquiry_phone', coalesce(nullif(e.phone, ''), ''), 'enquiry_about', what,
          'enquiry_dates', coalesce(nullif(e.dates, ''), ''), 'enquiry_people', coalesce(e.people::text, ''),
          'message', coalesce(e.message, ''), 'message_html', public.pm_html_text(coalesce(e.message, '')),
          'page_url', 'https://www.nomadwise.io/coworking/' || coalesce(v.webflow_slug, '')));
      purl := 'https://api.postmarkapp.com/email/withTemplate';
    end if;
  exception when others then
    purl := 'https://api.postmarkapp.com/email';
  end;
  select net.http_post(
    url := purl,
    body := payload,$a$,
'url := purl');

-- Switched on 5 Nov 2026 after pm_check_sent matched every case (free
-- enquiries with and without details, three kinds of held enquiry, a
-- price-list message, a team test, an unclaimed space, the follow-up,
-- and a Premium enquiry checked against today's text):
update public.email_templates set live = true, updated_at = now()
 where alias in ('enquiry-to-space','enquiry-sent-nomad','enquiry-waiting','enquiry-received-nomad',
                 'enquiry-premium-direct','enquiry-followup-nomad')
   and not live;

-- ============================================================
-- Migration 194: the enquiry emails, polished, previewed and editable.
--
-- Jonathan, 22 Oct 2026, before passing Ellie's six enquiries on: "make
-- sure you get this wording absolutely professional ... Leonie and I
-- really care about having the best customer service possible to both
-- the customer and coworking spaces", "I need to see if they are styled
-- or not ... what a preview will look like", "I need to have the
-- ability to update / edit any of the details".
--
--   * New words. To the space: "New enquiry for <space> from
--     Nomadwise", the customer's details laid out, their message, how to
--     reply, and a short "About your listing". To the customer: "Your
--     enquiry has been sent", the space(s), replies come straight to
--     them, help if they do not hear back.
--   * One place builds each email: enquiry_space_email(id) and
--     enquiry_nomad_email(ids). admin_enquiry_drafts(ids) hands the
--     drafts to Nomad Maps, which shows them styled (admin_email_preview,
--     the same template the emails are sent with) and lets a founder
--     change the address, subject and words before sending.
--   * admin_enquiry_pass_on and admin_enquiries_tell_nomad take the
--     edited subject and words (both optional: without them, the drafts
--     above are sent, as before). The older versions are replaced.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

-- ------------------------------------------------ the words

-- The email to the space for one enquiry: {subject, body}.
create or replace function public.enquiry_space_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  pitch text;
  first text;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if v.listing_tier = 'verified' then
    pitch := 'Your Verified page does not have an enquiry address yet. Add one in '
          || 'your Owner account and future enquiries will reach you directly:' || E'\n'
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'About your listing' || E'\n'
          || v.name || ' is listed on Nomadwise free of charge, based on publicly '
          || 'available information. You can claim the page at no cost to keep your '
          || 'details up to date and add your own photos, prices and opening hours:' || E'\n'
          || 'https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'About your listing' || E'\n'
          || 'Enquiries for your page currently come to us first, and we pass them on '
          || 'to you. With a Verified listing they reach your inbox directly, and your '
          || 'page is shown with the Verified badge above other listings in '
          || coalesce(nullif(v.city, ''), 'your city') || ':' || E'\n'
          || 'https://nomadmaps.io/?owner&billing';
  end if;

  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',
    'body',
      'Hi ' || v.name || ' team,' || E'\n\n'
      || 'You have a new enquiry from a remote worker who found '
      || case when page is not null then 'your page' else 'you' end
      || ' on Nomadwise' || coalesce(': ' || page, '.') || E'\n\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email || E'\n'
      || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
      || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                     when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                     when 'event' then 'Interested in: a meeting or event' || E'\n'
                     else '' end
      || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
      || coalesce('People: ' || e.people::text || E'\n', '')
      || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY') || E'\n\n'
      || 'Their message:' || E'\n'
      || coalesce(nullif(btrim(e.message), ''), '(No message)') || E'\n\n'
      || 'To reply, simply answer this email. Your reply goes directly to '
      || coalesce(first, 'them') || '.' || E'\n\n'
      || pitch || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise');
end $$;
revoke all on function public.enquiry_space_email(uuid) from public, anon, authenticated;

-- The email to the customer about one or several of their enquiries:
-- {to, subject, body}. Any status (it is drafted before passing on).
create or replace function public.enquiry_nomad_email(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  em    text;
  nm    text;
  first text;
  n     integer;
  one   text;
  site  text;
  lines text;
  sites boolean;
begin
  select lower(min(e.email)), min(e.name), count(*), min(v.name), min(v.website),
         string_agg('- ' || v.name
                    || coalesce(' (' || nullif(btrim(coalesce(v.website, '')), '') || ')', ''),
                    E'\n' order by v.name),
         bool_or(coalesce(btrim(v.website), '') <> '')
    into em, nm, n, one, site, lines, sites
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.id = any(p_ids);
  if coalesce(n, 0) = 0 then return null; end if;
  first := nullif(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone');

  if n = 1 then
    return jsonb_build_object(
      'to', em,
      'subject', 'Your enquiry has been sent to ' || one,
      'body',
        'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
        || 'Thank you for your enquiry on Nomadwise. We have sent it to ' || one
        || ', and their reply will come straight to this email address.' || E'\n\n'
        || case when coalesce(btrim(site), '') <> ''
                then 'If you would like to contact them yourself as well, their website is '
                     || btrim(site) || E'\n\n'
                else '' end
        || 'If you do not hear back, or would like help finding the right space, simply '
        || 'reply to this email and we will be glad to help.' || E'\n\n'
        || 'Kind regards,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise');
  end if;

  return jsonb_build_object(
    'to', em,
    'subject', 'Your enquiry has been sent to ' || n || ' spaces',
    'body',
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thank you for your enquiry on Nomadwise. We have sent it to these '
      || n || ' spaces:' || E'\n\n'
      || lines || E'\n\n'
      || 'Their replies will come straight to this email address.'
      || case when sites
              then ' If you would like to contact any of them yourself, their websites '
                   || 'are listed above.'
              else '' end || E'\n\n'
      || 'If you do not hear back, or would like help comparing your options, simply '
      || 'reply to this email and we will be glad to help.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan' || E'\n' || 'Nomadwise');
end $$;
revoke all on function public.enquiry_nomad_email(uuid[]) from public, anon, authenticated;

-- For Nomad Maps: the drafts for these enquiries, to show and edit
-- before sending. {spaces: [{id, venue_name, subject, body}], nomad:
-- {to, subject, body}} (nomad only for the ones matched to a space).
create or replace function public.admin_enquiry_drafts(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'spaces', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'venue_name', v.name)
                       || public.enquiry_space_email(e.id) order by v.name)
        from public.enquiries e
        join public.venues v on v.id = e.venue_id
       where e.id = any(p_ids)), '[]'::jsonb),
    'nomad', public.enquiry_nomad_email(p_ids));
end $$;
revoke all on function public.admin_enquiry_drafts(uuid[]) from public, anon;
grant execute on function public.admin_enquiry_drafts(uuid[]) to authenticated;

-- What an email will look like: the same template it is sent with.
create or replace function public.admin_email_preview(p_text text)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return public.owner_email_html(coalesce(p_text, ''));
end $$;
revoke all on function public.admin_email_preview(text) from public, anon;
grant execute on function public.admin_email_preview(text) to authenticated;

-- ------------------------------------------------ sending

drop function if exists public.admin_enquiry_pass_on(uuid, text, boolean);

-- Pass on: to the space (reply-to the customer), with the founder's
-- subject and words when given, and when asked a line to the customer.
create or replace function public.admin_enquiry_pass_on(
  p_id uuid, p_to text, p_tell_nomad boolean default true,
  p_subject text default null, p_body text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  dest  text := lower(trim(coalesce(p_to, '')));
  draft jsonb;
  nd    jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if dest !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That does not look like an email address.';
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
  draft := public.enquiry_space_email(p_id);

  perform public.send_enquiry_mail(
    dest, e.email,
    coalesce(nullif(btrim(p_subject), ''), draft ->> 'subject'),
    coalesce(nullif(btrim(p_body), ''), draft ->> 'body'),
    'enquiry_passed', e.id::text, v.id);

  update public.enquiries
     set status = 'passed', passed_to = dest, passed_at = now(),
         to_email = dest, sent_at = now(), send_error = null
   where id = p_id;

  -- Remember the address for the next one.
  update public.venues
     set contact_emails = array_prepend(dest, array_remove(coalesce(contact_emails, '{}'), dest))
   where id = v.id;

  if p_tell_nomad then
    nd := public.enquiry_nomad_email(array[p_id]);
    perform public.send_enquiry_mail(
      e.email, 'hello@nomadwise.io', nd ->> 'subject', nd ->> 'body',
      'enquiry_passed_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
  end if;

  return jsonb_build_object('status', 'passed', 'to', dest);
end $$;
revoke all on function public.admin_enquiry_pass_on(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.admin_enquiry_pass_on(uuid, text, boolean, text, text) to authenticated;

drop function if exists public.admin_enquiries_tell_nomad(uuid[]);
drop function if exists public.admin_enquiries_tell_nomad(uuid[], text, text);

-- One email to the customer listing every space their enquiry went
-- to (only the ones passed on and not told yet; all from one person),
-- with the founder's address, subject and words when given.
create or replace function public.admin_enquiries_tell_nomad(
  p_ids uuid[], p_subject text default null, p_body text default null,
  p_to text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ids   uuid[];
  draft jsonb;
  ref   uuid;
  dest  text := nullif(lower(btrim(coalesce(p_to, ''))), '');
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  select array_agg(e.id), min(e.id::text)::uuid into ids, ref
    from public.enquiries e
   where e.id = any(p_ids) and e.status = 'passed' and e.nomad_emailed_at is null;
  if coalesce(array_length(ids, 1), 0) = 0 then
    return jsonb_build_object('told', 0);
  end if;
  if (select count(distinct lower(e.email)) from public.enquiries e where e.id = any(ids)) > 1 then
    raise exception 'These enquiries are from different people.';
  end if;
  if dest is not null and dest !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That does not look like an email address.';
  end if;
  draft := public.enquiry_nomad_email(ids);

  perform public.send_enquiry_mail(
    coalesce(dest, draft ->> 'to'), 'hello@nomadwise.io',
    coalesce(nullif(btrim(p_subject), ''), draft ->> 'subject'),
    coalesce(nullif(btrim(p_body), ''), draft ->> 'body'),
    'enquiry_passed_nomad', ref::text, null, null);

  update public.enquiries set nomad_emailed_at = now() where id = any(ids);
  return jsonb_build_object('told', array_length(ids, 1));
end $$;
revoke all on function public.admin_enquiries_tell_nomad(uuid[], text, text, text) from public, anon;
grant execute on function public.admin_enquiries_tell_nomad(uuid[], text, text, text) to authenticated;

notify pgrst, 'reload schema';

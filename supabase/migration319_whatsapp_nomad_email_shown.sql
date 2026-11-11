-- ============================================================
-- Migration 319: passing on by WhatsApp shows the customer's email
-- ============================================================
-- Jonathan, 11 Nov 2026, with the WhatsApp window open on Alessandro's
-- enquiry to Coworking Space H24: "how do i know the customer will
-- receive the text i want", and "i just want to be able to see what
-- will be sent". The email route has "Check the emails"; the WhatsApp
-- route (migration 316) showed only the message to the space and sent
-- the customer's email unseen.
--
-- * enquiry_nomad_whatsapp_email(): the email the customer gets when
--   their enquiry went by WhatsApp, in one place (it was built inside
--   admin_enquiry_passed_whatsapp).
-- * admin_enquiry_whatsapp_draft() also returns it (nomad_to,
--   nomad_subject, nomad_body), so the window can show it.
-- * admin_enquiry_passed_whatsapp() takes the subject and words as he
--   left them in the window; empty means the draft.
-- ============================================================

create or replace function public.enquiry_nomad_whatsapp_email(p_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
           'to', nd ->> 'to',
           'subject', nd ->> 'subject',
           'body', replace(nd ->> 'body',
                           ', and their reply will come straight to your email address.',
                           ' by WhatsApp, and asked them to reply to you directly.'))
    from (select public.enquiry_nomad_email(array[p_id]) as nd) x
   where nd is not null;
$function$;

revoke all on function public.enquiry_nomad_whatsapp_email(uuid) from public, anon, authenticated;

create or replace function public.admin_enquiry_whatsapp_draft(p_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  nd jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  nd := public.enquiry_nomad_whatsapp_email(p_id);
  return jsonb_build_object(
    'text', public.enquiry_whatsapp_text(p_id),
    'nomad_to', nd ->> 'to',
    'nomad_subject', nd ->> 'subject',
    'nomad_body', nd ->> 'body');
end $function$;

-- Two more things to pass in, so the four-argument one goes (an app
-- still open from before calls with the same four names and lands on
-- this one, the last two left at their defaults).
drop function if exists public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean);

create or replace function public.admin_enquiry_passed_whatsapp(
  p_id uuid, p_phone text, p_body text default null, p_tell_nomad boolean default true,
  p_nomad_subject text default null, p_nomad_body text default null)
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
  -- the customer's email as drafted, before the enquiry changes state
  nd := public.enquiry_nomad_whatsapp_email(p_id);

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
    -- In plain words (no template), as shown in the window and as he
    -- left them there.
    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io',
      coalesce(nullif(btrim(p_nomad_subject), ''), nd ->> 'subject'),
      coalesce(nullif(btrim(p_nomad_body), ''), nd ->> 'body'),
      'enquiry_passed_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
    told := true;
  end if;

  return jsonb_build_object('status', 'passed', 'to', 'WhatsApp ' || ph, 'told', told);
end $function$;

revoke all on function public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean, text, text) from public, anon;
grant execute on function public.admin_enquiry_passed_whatsapp(uuid, text, text, boolean, text, text) to authenticated;

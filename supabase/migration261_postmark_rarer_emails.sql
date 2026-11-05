-- ============================================================
-- Migration 261: the three rarer emails get their Postmark templates too.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Nov 2026: "can you do the 3 rarer emails".
--  * site-chat-reply: a reply from the team in the chat on nomadwise.io,
--    emailed when the visitor has left (site_chat_email_sync).
--  * enquiry-unreachable-nomad: the nomad is told we could not reach the
--    space (admin_enquiry_close with "unreachable").
--  * enquiry-sent-nomad-many (and the single version): the nomad is told
--    their request went to the spaces (admin_enquiries_tell_nomad). Only
--    when the founder did not change the wording in the control centre;
--    an edited email goes out as written.
-- Same hand-over as migrations 259/260; nothing changes until the
-- template is switched on (email_templates.live).
-- ============================================================

select public.pm_patch_fn('public.site_chat_email_sync()',
$a$    perform public.send_owner_email(
      c.visitor_email,
      'Your chat with Nomadwise',$a$,
$a$    begin
      perform public.pm_set_model('site_chat', 'site-chat-reply',
        jsonb_build_object(
          'first_name', coalesce(split_part(nullif(btrim(c.visitor_name), ''), ' ', 1), ''),
          'asked', left(coalesce(asked, ''), 400),
          'message', words, 'message_html', public.pm_html_text(words),
          'from_name', coalesce(who, 'Jonathan')));
    exception when others then null; end;
    perform public.send_owner_email(
      c.visitor_email,
      'Your chat with Nomadwise',$a$,
'pm_set_model');

select public.pm_patch_fn('public.admin_enquiry_close(uuid,text,boolean)',
$a$    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io',
      'Your request for ' || v.name,$a$,
$a$    begin
      perform public.pm_set_model('enquiry_unreachable_nomad', 'enquiry-unreachable-nomad',
        jsonb_build_object(
          'greeting_name', coalesce(nullif(first, ''), 'there'), 'space_name', v.name,
          'ways', coalesce(ways, ''), 'ways_html', public.pm_html_text(coalesce(ways, '')),
          'has_ways', coalesce(ways, '') <> '', 'no_ways', coalesce(ways, '') = ''));
    exception when others then null; end;
    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io',
      'Your request for ' || v.name,$a$,
'pm_set_model');

select public.pm_patch_fn('public.admin_enquiries_tell_nomad(uuid[],text,text,text)',
$a$  perform public.send_enquiry_mail(
    coalesce(dest, draft ->> 'to'), 'spaces@nomadwise.io',$a$,
$a$  -- the template only for the wording as drafted; an edited email goes as written
  begin
    if nullif(btrim(coalesce(p_subject, '')), '') is null and nullif(btrim(coalesce(p_body, '')), '') is null then
      perform public.pm_set_model('enquiry_passed_nomad', draft ->> 'alias', draft -> 'model');
    end if;
  exception when others then null; end;
  perform public.send_enquiry_mail(
    coalesce(dest, draft ->> 'to'), 'spaces@nomadwise.io',$a$,
'pm_set_model');

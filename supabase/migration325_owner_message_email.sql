-- ============================================================
-- Migration 325: an owner's message also arrives by email
-- ============================================================
-- Jonathan, 12 Nov 2026, on Inbox & support in the Owner account: "is
-- it possible for the owner to be able to send me a message, which
-- will be sent to me, where I'll get a notification in my inbox", and
-- on where: spaces@nomadwise.io.
--
-- An owner could already write there (owner_chat_send): the message
-- goes under Chats in the control centre and the founders' phones are
-- pinged with who wrote, not what. Nothing reached an inbox.
--
-- Now the same message is also emailed to spaces@nomadwise.io: who
-- wrote and for which space, the message itself, and a link to answer
-- it in Chats. Reply-To is the owner's address, so a reply from the
-- inbox reaches them directly (it is not kept in the chat; the email
-- says so). The words go by email here because it is our own inbox;
-- the phone ping still says only who wrote. A failed email never
-- stops the message. Emails owners send to spaces@ themselves are not
-- touched (they already are in the inbox).
-- ============================================================

select public.pm_patch_fn('public.owner_chat_send(uuid, text)',
$a$  return jsonb_build_object('space', v.name, 'messages', public.chat_rows(p_venue, em));$a$,
$a$  -- and by email to our own inbox, with the words (migration 325)
  begin
    perform public.send_enquiry_mail(
      'spaces@nomadwise.io', em,
      'New message from ' || coalesce(v.name, 'a space'),
      coalesce(nullif(btrim(coalesce(v.listing_owner_name, '')), ''), 'The owner')
        || ' at **' || coalesce(v.name, 'a space') || '** wrote to you in Inbox & support.' || E'\n\n'
        || replace(replace(words, '](', '] ('), '**', '* *') || E'\n\n'
        || '[Answer in Chats](https://nomadmaps.io/chats/)' || E'\n\n'
        || 'Answering in Chats keeps your reply with the conversation. '
        || 'Replying to this email writes to ' || em || ' directly.',
      'owner_chat_notice', p_venue::text, p_venue, null);
  exception when others then
    null; -- an email never gets in the way of the message itself
  end;

  return jsonb_build_object('space', v.name, 'messages', public.chat_rows(p_venue, em));$a$,
$m$owner_chat_notice$m$);

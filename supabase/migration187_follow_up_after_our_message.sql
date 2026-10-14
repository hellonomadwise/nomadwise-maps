-- 187: a follow-up for a space we have already written to, once it
-- shows interest.
--
-- Jonathan, 14 Oct 2026, on Enosta Space (Da Nang): we wrote on
-- WhatsApp on 10 Oct, and on 12 Oct someone opened the claim page
-- through that message, twice, and began filling in their details.
-- "Write again" offered the message for a stranger ("Someone opened
-- the claim page ... If that was you"), which reads oddly to a space we
-- have already written to. He asked for a follow-up in its own words,
-- and only where there is a sign of interest: "im a little uncertain
-- about sending followup messages when it appears there is no
-- activity ... only if detecting that there is some potential
-- interest", with a good gap after the first message.
--
-- Two templates, one for email and one for WhatsApp (also used for
-- Instagram and Facebook). Outreach offers them by itself only when
-- (the app, same day):
--   * we have written to the space once, and they have not answered;
--   * the claim page was opened after that (the sign of interest);
--   * three days have passed since our message (before that, the card
--     says when a follow-up is due).
-- Without a sign of interest nothing is suggested. Nothing is sent by
-- itself.
-- Pure ASCII. Safe to apply twice.

insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('followup_after_ours', 'Follow-up: after our message, they showed interest',
 'Your page for {space}',
 'Hi {first_name},

Just checking in after my message about your page for {space} on Nomadwise. If you had any questions about claiming it, or anything was not clear, I am happy to help.

Claiming is free, and you can pick it up here: {claim_link}

{signoff}', 'outbound', 58),

('followup_after_ours_wa', 'WhatsApp: follow-up after our message',
 'WhatsApp',
 'Hi, it''s Jonathan from Nomadwise again. Just checking in after my message about your page for {space}. If you had any questions about claiming it, or anything wasn''t clear, I''m happy to help. Claiming is free, and you can pick it up here: {claim_link}

{signoff}', 'outbound', 59)
on conflict (key) do nothing;

-- ============================================================
-- Migration 265: one tidy signature on every email.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026, on "Your changes to ...": "I think the bottom
-- part with my signature looks a bit messy", showing the enquiry emails'
-- sign-off as the one to use: "Kind regards," / Jonathan Heavens (bold) /
-- "Co-founder, nomadwise.io" (nomadwise.io in Nomadwise red).
--
-- Changed in the templates (and pushed to Postmark by Claude the same
-- morning): claim emails, page live, changes on the page / sent back,
-- Premium ended, sign-in reminders 1 and 2, could not reach the space,
-- finish your claim (full name), website chat (signed by whoever replied).
-- pm_check_sent no longer counts sign-off lines as differences, since the
-- old code's sign-offs are now deliberately different.
-- ============================================================

do $t$
declare
  sig text := '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p><p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">Jonathan Heavens</p><p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;">Co-founder, <a href="https://www.nomadwise.io" style="color:#FF444F;font-weight:700;text-decoration:none;">nomadwise.io</a></p>';
  sigt text := E'Kind regards,\nJonathan Heavens\nCo-founder, Nomadwise';
begin
  update public.email_templates set
    html_body = replace(html_body, '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Jonathan<br>Nomadwise, <a href="https://www.nomadwise.io" style="color:#FF444F;text-decoration:underline;">https://www.nomadwise.io</a></p>', sig),
    text_body = replace(text_body, E'Jonathan\nNomadwise, https://www.nomadwise.io', sigt), updated_at = now()
  where html_body like '%>Jonathan<br>Nomadwise, <a href="https://www.nomadwise.io"%';
  update public.email_templates set
    html_body = replace(html_body, '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Jonathan</p>', sig),
    text_body = regexp_replace(text_body, E'\n\nJonathan$', E'\n\n' || sigt), updated_at = now()
  where alias in ('signin-reminder-1', 'signin-reminder-2')
    and html_body like '%color:#5C6773;">Jonathan</p>%';
  update public.email_templates set
    html_body = replace(html_body, '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Jonathan<br>Nomadwise</p>', sig),
    text_body = regexp_replace(text_body, E'\n\nJonathan\nNomadwise$', E'\n\n' || sigt), updated_at = now()
  where alias = 'enquiry-unreachable-nomad' and html_body like '%>Jonathan<br>Nomadwise</p>%';
  update public.email_templates set
    html_body = replace(html_body, '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Kind regards,<br>{{from_name}}<br>nomadwise&#8203;.io</p>',
      '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p><p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">{{from_name}}</p><p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;"><a href="https://www.nomadwise.io" style="color:#FF444F;font-weight:700;text-decoration:none;">nomadwise.io</a></p>'),
    updated_at = now()
  where alias = 'site-chat-reply' and html_body like '%Kind regards,<br>{{from_name}}<br>%';
  update public.email_templates set
    html_body = replace(html_body, 'font-weight:700;color:#142032;">Jonathan</p>', 'font-weight:700;color:#142032;">Jonathan Heavens</p>'),
    text_body = replace(text_body, E'Kind regards,\nJonathan\nCo-founder', E'Kind regards,\nJonathan Heavens\nCo-founder'), updated_at = now()
  where alias = 'finish-claim' and html_body like '%color:#142032;">Jonathan</p>%';
end $t$;

select public.pm_patch_fn('public.pm_check_sent(timestamptz)',
  $a$!~ pat;$a$,
  $a$!~ pat
       and btrim(l) <> all (array['Kind regards,', 'Jonathan', 'Jonathan Heavens', 'Co-founder, Nomadwise',
                                 'Nomadwise', 'Nomadwise, https://www.nomadwise.io', 'nomadwise.io', 'Nomadwise.io']);$a$,
  $a$'Co-founder, Nomadwise',$a$);

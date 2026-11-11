-- ============================================================
-- Migration 314: "You now manage X" no longer mentions Premium
-- ============================================================
-- Jonathan, 11 Nov 2026, on the email Olga (Stone Soup) got when her
-- claim was approved: "can we also make this one softer, in terms of
-- mentioning premium. I think this will be clear to them when they
-- login. this isn't where to push for a sale", and "I do like the
-- mention of the 'find us on Nomadwise'".
--
-- The paragraph "When you want more, Nomadwise Premium is €10 a month
-- or €96 a year: ..." goes from the email, in all three places it is
-- written: the Postmark template's HTML and text (email_templates,
-- alias claim-approved-free) and the plain words claim_emails() keeps
-- as a fallback. The badge paragraph and everything else stay.
-- Premium is in the Owner account, under Plan & billing.
--
-- The template is pushed to Postmark by hand after this
-- (pm_template_push('claim-approved-free', true)); done on the day,
-- after pm_templates_backup().
-- ============================================================

update public.email_templates
   set html_body = replace(html_body,
         $h$<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">When you want more, Nomadwise Premium is {{price_words}}: the Verified by Nomadwise badge, top positioning on your region's page, unlimited enquiries straight to your inbox, and your own events and offers on your page. You will find it under Plan &amp; billing in your Owner account.</p>
$h$, ''),
       text_body = replace(text_body,
         $t$When you want more, Nomadwise Premium is {{price_words}}: the Verified by Nomadwise badge, top positioning on your region's page, unlimited enquiries straight to your inbox, and your own events and offers on your page. You will find it under Plan & billing in your Owner account.

$t$, ''),
       updated_at = now()
 where alias = 'claim-approved-free'
   and (html_body like '%When you want more, Nomadwise Premium%'
        or text_body like '%When you want more, Nomadwise Premium%');

select public.pm_patch_fn('public.claim_emails()',
$a$         || 'it goes on the page.' || E'\n\n'
         || 'When you want more, Nomadwise Premium is '
         || public.verified_price_words(coalesce((select country from public.venues where id = new.venue_id), new.space_country))
         || ': the Verified by Nomadwise badge, top positioning on your region''s '
         || 'page, unlimited enquiries straight to your inbox, and your own events and '
         || 'offers on your page. You will find it under Plan & billing in your Owner '
         || 'account.'
         || owner_line || sig;$a$,
$a$         || 'it goes on the page.'
         -- (no word of Premium here: it is in the Owner account. Migration 314)
         || owner_line || sig;$a$,
$m$no word of Premium here: it is in the Owner account. Migration 314$m$);

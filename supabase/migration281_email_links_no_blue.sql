-- ============================================================
-- Migration 281: no more blue links in the emails.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026 (a live changes-live email): an email address
-- and "nomadmaps.io/owner" showed in blue. They were plain text, and
-- the mail app turned them into its own blue links. Now:
--  * nomadmaps.io/owner is a real link, in Nomadwise red;
--  * an address the reader would write to (the nomad's email in a
--    request to a space) is a red link;
--  * an address shown for information (the owner's own sign-in address,
--    the address requests go to, the nomad's own address) is a link in
--    the text colour with no underline, so it reads as plain text and
--    the mail app leaves it alone.
-- The templates are then pushed to Postmark by hand.
-- ============================================================

update public.email_templates
   set html_body = replace(replace(html_body,
         'we send a link to {{owner_email}}, no password',
         'we send a link to <a href="mailto:{{owner_email}}" style="color:#142032;text-decoration:none;">{{owner_email}}</a>, no password'),
         'bookmark nomadmaps.io/owner to come',
         'bookmark <a href="https://nomadmaps.io/owner" style="color:#FF444F;text-decoration:underline;">nomadmaps.io/owner</a> to come'),
       updated_at = now()
 where alias in ('changes-live', 'changes-returned') and html_body like '%link to {{owner_email}},%';

update public.email_templates
   set html_body = replace(html_body, 'come straight to {{enquiry_address}}.',
         'come straight to <a href="mailto:{{enquiry_address}}" style="color:#142032;text-decoration:none;">{{enquiry_address}}</a>.'),
       updated_at = now()
 where alias = 'claim-approved-premium' and html_body like '%straight to {{enquiry_address}}.%';

update public.email_templates
   set html_body = replace(html_body, 'from the page go to {{../enquiry_address}}.',
         'from the page go to <a href="mailto:{{../enquiry_address}}" style="color:#142032;text-decoration:none;">{{../enquiry_address}}</a>.'),
       updated_at = now()
 where alias = 'page-live' and html_body like '%go to {{../enquiry_address}}.%';

-- to the space: the nomad's address is the one to write to
update public.email_templates
   set html_body = replace(replace(html_body,
         '&lt;{{enquiry_email}}&gt;',
         '&lt;<a href="mailto:{{enquiry_email}}" style="color:#FF444F;text-decoration:underline;">{{enquiry_email}}</a>&gt;'),
         '<br>Email: {{enquiry_email}}',
         '<br>Email: <a href="mailto:{{enquiry_email}}" style="color:#FF444F;text-decoration:underline;">{{enquiry_email}}</a>'),
       updated_at = now()
 where alias in ('enquiry-premium-direct', 'enquiry-to-space') and html_body like '%{{enquiry_email}}%'
   and html_body not like '%mailto:{{enquiry_email}}%';

-- to the nomad: their own address, for information
update public.email_templates
   set html_body = replace(html_body, '<br>Email: {{enquiry_email}}',
         '<br>Email: <a href="mailto:{{enquiry_email}}" style="color:#142032;text-decoration:none;">{{enquiry_email}}</a>'),
       updated_at = now()
 where alias in ('enquiry-received-nomad', 'enquiry-sent-nomad') and html_body like '%Email: {{enquiry_email}}%'
   and html_body not like '%mailto:{{enquiry_email}}%';

-- ============================================================
-- Migration 262: links in Nomadwise red, and real paragraphs, in the
-- text people write that goes into a template email.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026, test pairs 20-22: "on new the links are blue, on
-- the current they are red" and "on 20 i think there is some spacing out
-- of alignment". pm_html_text (chat messages, enquiry messages, the ways
-- to reach a space, the list of spaces) now turns web addresses into
-- links in Nomadwise red #FF444F, like today's emails, and a blank line
-- starts a new paragraph in the template's own paragraph style instead
-- of two line breaks.
-- ============================================================

create or replace function public.pm_html_text(p text) returns text
language sql immutable as $$
  select replace(
           regexp_replace(
             regexp_replace(
               replace(replace(replace(replace(
                 regexp_replace(coalesce(p, ''), '^\s+|\s+$', '', 'g'),
                 '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'),
               '(https?://[^\s<]*[^\s<.,;:!?)])',
               '<a href="\1" style="color:#FF444F;text-decoration:underline;">\1</a>', 'g'),
             '\n[ \t]*\n\s*',
             '</p><p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">', 'g'),
           E'\n', '<br>')
$$;

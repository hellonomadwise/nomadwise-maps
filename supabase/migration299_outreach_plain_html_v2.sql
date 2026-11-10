-- ============================================================
-- Migration 299: outreach emails look right in every mail app
-- ============================================================
-- Jonathan, 9 Nov 2026, showing the email to The Capsule in Spark:
-- "This is how the email looks when it comes from nomadmaps. Can we
-- make it better?" It came in a serif font with two long addresses
-- written out, and no button.
--
-- 1. The font is now set on the body, a table cell and every
--    paragraph, not only on one outer box: some mail apps (Spark) drop
--    the outer box's font and fall back to Times.
-- 2. The claim link became nomadwise.io/claim/... in migration 293,
--    which this function did not know, so the "Claim your page" button
--    stopped showing and the address was written out instead. Both
--    kinds of claim link make the button again, and the Owner sign-in
--    (nomadmaps.io/owner) makes an "Open your Owner account" button.
-- 3. "... your page: https://www.nomadwise.io/coworking/x" now reads
--    "... your page." with "your page" as the link, the same as
--    "nomadwise.io: <address>" already did.
-- 4. The sign-off became "Co-founder, nomadwise.io" in the email words,
--    which the signature look did not know, so it came as three plain
--    lines. Both wordings now make the signature.
-- 5. A line that only said "Claim your page:" goes when its link
--    becomes the button.
-- ============================================================

create or replace function public.outreach_plain_html(p_body text)
returns text
language plpgsql
immutable
as $function$
declare
  main   text := coalesce(p_body, '');
  url    text;
  cut    text;
  paras  text[];
  p      text;
  claim  text;
  label  text;
  page   text;
  yours  text;
  html   text := '';
  n      integer;
  i      integer;
  font   constant text := 'font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,Helvetica,Arial,sans-serif;';
  para   constant text := 'margin:0 0 16px 0;font-size:15px;line-height:1.6;color:#1F2933;';
begin
  if btrim(main) = '' then return null; end if;

  -- the unsubscribe address, in the last paragraph (as migration 174)
  url := substring(main from '(https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+)\s*$');
  if url is not null then
    cut := regexp_replace(main,
             '\n\n[^\n]*https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+\s*$', '');
    if cut = main then url := null; else main := cut; end if;
  end if;

  paras := regexp_split_to_array(btrim(replace(main, E'\r', '')), E'\\n\\s*\\n');
  n := coalesce(array_length(paras, 1), 0);
  for i in 1 .. n loop
    p := btrim(paras[i]);
    if p = '' then continue; end if;

    -- the sign-off as a letter (migration 183)
    -- (the role line as either sign-off has had it: "Cofounder -
    -- Nomadwise.io" or "Co-founder, nomadwise.io")
    if p ~* '^Kind regards,\s*\n\s*Jonathan Heavens\s*\n\s*Co-?founder(,| -) Nomadwise\.io$' then
      html := html
        || '<p style="' || font || 'margin:0;font-size:15px;line-height:1.6;color:#1F2933;">Kind regards,</p>'
        || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:14px 0 0 0;border-collapse:collapse;">'
        || '<tr><td style="' || font || 'padding:12px 0 0 0;border-top:1px solid #E6E9ED;">'
        || '<div style="' || font || 'font-size:15px;font-weight:700;color:#142032;">Jonathan Heavens</div>'
        || '<div style="' || font || 'font-size:13px;line-height:1.5;color:#5C6773;">Co-founder &middot; '
        || '<a href="https://www.nomadwise.io" style="' || font || 'color:#FF444F;font-weight:700;text-decoration:none;">Nomadwise.io</a>'
        || '</div></td></tr></table>';
      continue;
    end if;

    -- the earlier sign-off: a small signature under a thin line
    if p ~ '^Jonathan\s*\n\s*Nomadwise, https://www\.nomadwise\.io/?$' then
      html := html
        || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 0 0;border-collapse:collapse;">'
        || '<tr><td style="' || font || 'padding:14px 0 0 0;border-top:1px solid #E6E9ED;">'
        || '<div style="' || font || 'font-size:15px;font-weight:700;color:#142032;">Jonathan</div>'
        || '<div style="' || font || 'font-size:13px;line-height:1.5;color:#5C6773;">'
        || '<a href="https://www.nomadwise.io" style="' || font || 'color:#FF444F;font-weight:700;text-decoration:none;">Nomadwise</a>'
        || '</div></td></tr></table>';
      continue;
    end if;

    -- the claim address (either kind) or the Owner sign-in: taken out of
    -- the sentence, shown as a button
    claim := substring(p from '(https://(nomadmaps\.io/\?claim=|nomadwise\.io/claim/|nomadmaps\.io/owner)[^\s<>"]*)');
    if claim is not null then
      claim := regexp_replace(claim, '[.,;:!?)]+$', '');
      -- taken out with the space and line break it leaves, and a line
      -- that only said "Claim your page:" goes too (the button says it)
      p := regexp_replace(replace(p, claim, ''), '^\s+|\s+$', '', 'g');
      p := regexp_replace(p, '(^|\n)[ \t]*Claim your page:?[ \t]*(\n|$)', '\1', 'g');
      p := regexp_replace(p, '^\s+|\s+$', '', 'g');
      label := case when claim like 'https://nomadmaps.io/owner%'
                    then 'Open your Owner account' else 'Claim your page' end;
    end if;

    -- "... is already on nomadwise.io: <page>" reads "... on nomadwise.io."
    -- with the words as the link (Jonathan, 26 Oct 2026: "it's repeating")
    page := substring(p from 'nomadwise\.io:\s*(https://www\.nomadwise\.io/[^\s<>"]*[^\s<>".,;:!?)])\s*\.?\s*$');
    if page is not null then
      p := regexp_replace(p, 'nomadwise\.io:\s*https://www\.nomadwise\.io/\S*\s*$', 'ZZPAGELINKZZ.');
    end if;
    -- and "... your page: <page>" reads "... your page." the same way
    yours := substring(p from 'your page:\s*(https://www\.nomadwise\.io/[^\s<>"]*[^\s<>".,;:!?)])\s*\.?\s*$');
    if yours is not null then
      p := regexp_replace(p, 'your page:\s*https://www\.nomadwise\.io/\S*\s*$', 'ZZYOURPAGEZZ.');
    end if;

    if p <> '' then
      -- escaped, links made clickable and shown short, single line
      -- breaks kept
      p := replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      p := regexp_replace(p, '(https?://)(www\.)?([^\s<]+[^\s<.,;:!?)])',
                          '<a href="\1\2\3" style="color:#FF444F;text-decoration:underline;">\3</a>', 'g');
      p := regexp_replace(p, '(^|[\s(])www\.([^\s<]+[^\s<.,;:!?)])',
                          '\1<a href="https://www.\2" style="color:#FF444F;text-decoration:underline;">\2</a>', 'g');
      p := replace(p, E'\n', '<br>');
      if page is not null then
        p := replace(p, 'ZZPAGELINKZZ',
               '<a href="' || replace(page, '&', '&amp;') || '" style="color:#FF444F;text-decoration:underline;">nomadwise.io</a>');
      end if;
      if yours is not null then
        p := replace(p, 'ZZYOURPAGEZZ',
               '<a href="' || replace(yours, '&', '&amp;') || '" style="color:#FF444F;text-decoration:underline;">your page</a>');
      end if;
      html := html || '<p style="' || font || para || '">' || p || '</p>';
    end if;

    if claim is not null then
      html := html
        -- Outlined, not filled: Gmail's dark mode turned the white words
        -- on the red button dark (Jonathan, 26 Oct 2026). Red words in a
        -- red frame read in light and dark alike.
        || '<p style="' || font || 'margin:2px 0 22px 0;">'
        || '<a href="' || replace(claim, '&', '&amp;') || '" '
        || 'style="' || font || 'display:inline-block;border:2px solid #FF444F;color:#FF444F;'
        || 'text-decoration:none;font-weight:700;font-size:15px;line-height:1.2;'
        || 'padding:11px 22px;border-radius:8px;">' || label || '</a></p>';
    end if;
  end loop;

  if url is not null then
    html := html
      || '<p style="' || font || 'margin:22px 0 0 0;font-size:12px;line-height:1.5;color:#8A94A0;">'
      || 'If you would rather not hear from us again, '
      || '<a href="' || url || '" style="color:#8A94A0;text-decoration:underline;">unsubscribe here</a>.'
      || '</p>';
  end if;

  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      || '<meta name="viewport" content="width=device-width,initial-scale=1"></head>'
      || '<body style="margin:0;padding:0;background:#FFFFFF;' || font || 'color:#1F2933;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
      || '<tr><td style="' || font || 'font-size:15px;line-height:1.6;color:#1F2933;padding:12px 6px;">'
      || '<div style="max-width:560px;">' || html || '</div>'
      || '</td></tr></table></body></html>';
exception when others then
  return null;
end $function$;

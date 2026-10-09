-- 180: a first Outreach email that looks professional and still reads
-- like a person's email.
--
-- Jonathan, 9 Oct 2026, after the hello to Level39: "I would ideally
-- like the outreach email to have a balance between no styling and
-- looking professional". Until now an Outreach email to a space that
-- has not claimed went as plain text in HTML form (migration 174): the
-- long claim address written out in full, the page address with
-- https://www., the sign-off as two plain lines. He chose plain on
-- 7 Oct so first emails land in the inbox and not under Promotions
-- (migration 163), so the middle way keeps what helps with that: no
-- pictures, no logo, no coloured card or background, one column of
-- ordinary text. What changes, in the HTML version only (the plain
-- text that travels with it is untouched):
--   * the claim address becomes one button, "Claim your page", under
--     the sentence that leads to it;
--   * other addresses are shown short (nomadwise.io/coworking/...),
--     the link behind them unchanged;
--   * the sign-off "Jonathan / Nomadwise, https://www.nomadwise.io"
--     becomes a small signature under a thin line: the name, then
--     Nomadwise in its red and nomadwise.io;
--   * the type is a little roomier (15px, 1.6 line height, 560px wide);
--   * the unsubscribe line stays small and grey at the foot.
-- Emails to spaces that have claimed keep the designed card (163), and
-- emails sent from a founder's own inbox are not touched.
-- Pure ASCII. Safe to apply twice.

create or replace function public.outreach_plain_html(p_body text)
returns text language plpgsql immutable as $$
declare
  main   text := coalesce(p_body, '');
  url    text;
  cut    text;
  paras  text[];
  p      text;
  claim  text;
  html   text := '';
  n      integer;
  i      integer;
begin
  if btrim(main) = '' then return null; end if;

  -- the unsubscribe address, in the last paragraph (as migration 174)
  url := substring(main from '(https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+)\s*$');
  if url is not null then
    cut := regexp_replace(main,
             '\n\n[^\n]*https://nomadmaps\.io/\?unsubscribe=[0-9A-Za-z_-]+\s*$', '');
    if cut = main then url := null; else main := cut; end if;
  end if;

  paras := regexp_split_to_array(btrim(replace(main, E'\r', '')), E'\n\\s*\n');
  n := coalesce(array_length(paras, 1), 0);
  for i in 1 .. n loop
    p := btrim(paras[i]);
    if p = '' then continue; end if;

    -- our sign-off: a small signature under a thin line
    if p ~ '^Jonathan\s*\n\s*Nomadwise, https://www\.nomadwise\.io/?$' then
      html := html
        || '<div style="margin:26px 0 0 0;padding-top:14px;border-top:1px solid #E6E9ED;">'
        || '<div style="font-weight:600;color:#142032;">Jonathan</div>'
        || '<div style="font-size:13px;line-height:1.5;color:#5C6773;">'
        || '<span style="color:#FF444F;font-weight:700;">Nomadwise</span>'
        || ' &middot; <a href="https://www.nomadwise.io" style="color:#5C6773;text-decoration:none;">nomadwise.io</a>'
        || '</div></div>';
      continue;
    end if;

    -- the claim address: taken out of the sentence, shown as a button
    claim := substring(p from '(https://nomadmaps\.io/\?claim=[^\s<>"]+)');
    if claim is not null then
      claim := regexp_replace(claim, '[.,;:!?)]+$', '');
      p := btrim(replace(p, claim, ''));
    end if;

    if p <> '' then
      -- escaped, links made clickable and shown short, single line
      -- breaks kept
      p := replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      p := regexp_replace(p, '(https?://)(www\.)?([^\s<]+[^\s<.,;:!?)])',
                          '<a href="\1\2\3" style="color:#1A56DB;">\3</a>', 'g');
      p := regexp_replace(p, '(^|[\s(])www\.([^\s<]+[^\s<.,;:!?)])',
                          '\1<a href="https://www.\2" style="color:#1A56DB;">\2</a>', 'g');
      p := replace(p, E'\n', '<br>');
      html := html || '<p style="margin:0 0 16px 0;">' || p || '</p>';
    end if;

    if claim is not null then
      html := html
        || '<p style="margin:2px 0 22px 0;">'
        || '<a href="' || replace(claim, '&', '&amp;') || '" '
        || 'style="display:inline-block;background:#FF444F;color:#FFFFFF;'
        || 'text-decoration:none;font-weight:600;font-size:15px;line-height:1.2;'
        || 'padding:12px 22px;border-radius:8px;">Claim your page</a></p>';
    end if;
  end loop;

  if url is not null then
    html := html
      || '<p style="margin:22px 0 0 0;font-size:12px;line-height:1.5;color:#8A94A0;">'
      || 'If you would rather not hear from us again, '
      || '<a href="' || url || '" style="color:#8A94A0;text-decoration:underline;">unsubscribe here</a>.'
      || '</p>';
  end if;

  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      || '<meta name="viewport" content="width=device-width,initial-scale=1"></head>'
      || '<body style="margin:0;padding:0;background:#FFFFFF;">'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:1.6;color:#1F2933;max-width:560px;padding:12px 6px;">'
      || html || '</div></body></html>';
exception when others then
  return null;
end $$;
revoke all on function public.outreach_plain_html(text) from public, anon, authenticated;

-- 183: outreach emails close as a letter, and no longer say "We will
-- not write again unless you reply."
--
-- Jonathan, 10 Oct 2026, on the hello to Level39: "this bottom bit, We
-- will not write again unless you reply. this should not be said. we
-- can finish it with Kind regards, Jonathan Heavens, Cofounder -
-- Nomadwise.io".
--   * every outreach template: the sentence is taken out (in
--     invite_listed, with the unsubscribe sentence that followed it:
--     every email already ends with the small unsubscribe line,
--     migration 174, so it was said twice);
--   * {signoff} in an email now reads
--       Kind regards,
--       Jonathan Heavens
--       Cofounder - Nomadwise.io
--     (a WhatsApp message keeps the short "Jonathan, Nomadwise");
--   * in the email's HTML version the name and role sit as a small
--     signature under a thin line, as migration 180 did for the old one.
-- A template reworded by hand without these exact words is left alone.
-- Pure ASCII. Safe to apply twice.

update public.outreach_templates
   set body = replace(replace(body,
                E'\n\nWe will not write again unless you reply. If you would rather not hear from us at all: {unsubscribe_link}', ''),
                E'\n\nWe will not write again unless you reply.', ''),
       updated_at = now()
 where body like '%We will not write again unless you reply.%';

create or replace function public.admin_outreach_preview(p_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  v   public.venues%rowtype;
  t   public.outreach_templates%rowtype;
  first_name text;
  space text;
  city  text;
  page_link text;
  claim_link text;
  price text;
  subj text;
  body text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  select * into t from public.outreach_templates where key = p_key;
  if not found then raise exception 'No such template.'; end if;
  if c.venue_id is not null then
    select * into v from public.venues where id = c.venue_id;
  end if;

  first_name := coalesce(nullif(split_part(trim(coalesce(c.person_name, '')), ' ', 1), ''), 'there');
  space := coalesce(nullif(trim(c.space_name), ''), v.name, 'your space');
  city  := coalesce(nullif(trim(c.city), ''), v.city, 'your city');
  page_link := case when v.webflow_cms_id is not null and coalesce(v.webflow_slug, '') <> ''
                    then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  -- (from= says where the link was sent, so a visit through it is
  -- known as an answer to our message: migration 156)
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
             || case when right(p_key, 3) = '_wa' then '&from=whatsapp' else '&from=email' end
             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;
  price := case when coalesce(v.country, c.country, '') <> ''
                     and coalesce((public.pricing_for(coalesce(v.country, c.country))->>'ready')::boolean, false)
                then public.verified_price_words(coalesce(v.country, c.country))
                else 'around a day pass a month' end;

  subj := t.subject; body := t.body;
  -- The subject takes the words, not the links.
  subj := replace(subj, '{space}', space);
  subj := replace(subj, '{first_name}', first_name);
  subj := replace(subj, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  subj := replace(subj, '{city}', city);
  body := replace(body, '{first_name}', first_name);
  body := replace(body, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  body := replace(body, '{space}', space);
  body := replace(body, '{city}', city);
  body := replace(body, '{page_link}', coalesce(page_link, 'https://www.nomadwise.io'));
  body := replace(body, '{claim_link}', claim_link);
  body := replace(body, '{price_words}', price);
  body := replace(body, '{unsubscribe_link}', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
  -- The sign-off (migration 183): an email closes as a letter; a
  -- WhatsApp message keeps the short one.
  body := replace(body, '{signoff}',
            case when right(p_key, 3) = '_wa'
                 then E'Jonathan\nNomadwise, https://www.nomadwise.io'
                 else E'Kind regards,\nJonathan Heavens\nCofounder - Nomadwise.io' end);
  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream,
                            'unsubscribe_link', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

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

    -- the sign-off as a letter (migration 183): "Kind regards," as
    -- written, then the name and role as a small signature under a
    -- thin line
    if p ~ '^Kind regards,\s*\n\s*Jonathan Heavens\s*\n\s*Cofounder - Nomadwise\.io$' then
      html := html
        || '<p style="margin:0;">Kind regards,</p>'
        || '<div style="margin:14px 0 0 0;padding-top:12px;border-top:1px solid #E6E9ED;">'
        || '<div style="font-weight:600;color:#142032;">Jonathan Heavens</div>'
        || '<div style="font-size:13px;line-height:1.5;color:#5C6773;">Cofounder - '
        || '<a href="https://www.nomadwise.io" style="color:#5C6773;text-decoration:none;">'
        || '<span style="color:#FF444F;font-weight:700;">Nomadwise</span>.io</a>'
        || '</div></div>';
      continue;
    end if;

    -- the earlier sign-off: a small signature under a thin line
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

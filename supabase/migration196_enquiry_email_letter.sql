-- ============================================================
-- Migration 196: enquiry emails read as a letter from the founder.
--
-- Jonathan, 22 Oct 2026, on the Step 2 preview:
--  * "About your listing" should be clearer, and what Nomadwise
--    offers should look separate from the customer's enquiry. It is
--    now a light grey panel with a bold heading, and its link is a
--    button ("Claim your page", "See Verified", "Open your Owner
--    account"). The plain-text email keeps the address.
--  * A better sign-off: "Kind regards," then "Jonathan Heavens" and
--    "Co-founder, Nomadwise" (name in bold, Nomadwise in red).
--  * Emails to the customer (not the space) no longer carry the
--    "FOR SPACES" tag or the Owner account link in the footer.
--
-- email_html() is the template; owner_email_html() keeps its three
-- arguments and calls it, so every owner email gets the panel and
-- sign-off styling only where those exact patterns appear (no other
-- email changes). Emails whose sign-off is still "Kind regards,
-- Jonathan, Nomadwise" get the same styled sign-off.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.email_html(
  p_text text, p_cta_label text default null, p_cta_url text default null,
  p_for_spaces boolean default true)
returns text language plpgsql immutable as $$
declare
  paras  text[];
  p      text;
  esc    text;
  body   text := '';
  n      int;
  i      int := 0;
  button text := '';
  pre    text := '';
  font   text := 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;';
  head   text;
  rest   text;
  url    text;
  lbl    text;
  who    text;
  role   text;
begin
  if coalesce(p_cta_label, '') <> '' and coalesce(p_cta_url, '') <> '' then
    button := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;">'
           || '<tr><td style="background:#E0442E;border-radius:10px;">'
           || '<a href="' || replace(p_cta_url, '"', '') || '" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">'
           || replace(replace(p_cta_label, '<', '&lt;'), '>', '&gt;') || '</a></td></tr></table>';
  end if;

  paras := regexp_split_to_array(coalesce(p_text, ''), E'\n\n+');
  n := coalesce(array_length(paras, 1), 0);

  -- The inbox preview: the first real sentence, not the greeting.
  if n >= 2 and paras[1] ~* '^(hi|hello)\M' then
    pre := paras[2];
  elsif n >= 1 then
    pre := paras[1];
  end if;
  pre := regexp_replace(pre, 'https?://[^[:space:]]+', '', 'g');
  pre := left(regexp_replace(pre, '[[:space:]]+', ' ', 'g'), 140);
  pre := replace(replace(replace(pre, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

  foreach p in array paras loop
    i := i + 1;
    p := btrim(replace(p, E'\r', ''), E' \n\t');

    -- The sign-off: "Kind regards," then the name in bold and the role.
    if p ~ '^Kind regards,[ \t]*\n[ \t]*Jonathan( Heavens)?[ \t]*\n[ \t]*(Co-founder, )?Nomadwise[ \t]*$' then
      who  := case when p ~ 'Jonathan Heavens' then 'Jonathan Heavens' else 'Jonathan' end;
      role := case when p ~ 'Co-founder, Nomadwise' then 'Co-founder, ' else '' end;
      body := body || case when i = n then button else '' end
           || '<p style="margin:8px 0 10px;font-size:16px;line-height:1.6;color:#142032;">Kind regards,</p>'
           || '<p style="margin:0;font-size:16px;line-height:1.4;font-weight:700;color:#142032;">' || who || '</p>'
           || '<p style="margin:2px 0 0;font-size:14px;line-height:1.5;color:#5C6773;">' || role
           || '<a href="https://www.nomadwise.io" style="color:#E0442E;font-weight:700;text-decoration:none;">Nomadwise</a></p>';
      if i = n then button := ''; end if;
      continue;
    end if;

    esc := replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
    -- "nomadwise.io" in a sentence: an invisible break stops mail apps
    -- linking it; full web addresses are linked below.
    esc := regexp_replace(esc, '(^|[^/.@[:alnum:]])nomadwise\.io\M', '\1nomadwise&#8203;.io', 'gi');

    -- "About your listing" (any short "About ..." first line): what we
    -- offer the space, set apart in a light panel; a link on its own
    -- last line becomes a button.
    if p ~ '^About [A-Za-z'' ]{3,40}\n' then
      head := split_part(esc, E'\n', 1);
      rest := substr(esc, length(head) + 2);
      url := substring(rest from '\n(https?://[^[:space:]<]+)$');
      lbl := null;
      if url is not null then
        lbl := case when url ~ '\?claim=' then 'Claim your page'
                    when url ~ '\?owner&amp;billing' then 'See Verified'
                    when url ~ '\?owner' then 'Open your Owner account'
                    else null end;
      end if;
      if lbl is not null then
        rest := left(rest, length(rest) - length(url) - 1);
      end if;
      rest := regexp_replace(rest, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                             '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
      rest := replace(rest, E'\n', '<br>');
      body := body
           || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 24px;">'
           || '<tr><td style="background:#F4F6F8;border-radius:12px;padding:20px 22px;">'
           || '<p style="margin:0 0 6px;font-size:15px;line-height:1.4;font-weight:700;color:#142032;">' || head || '</p>'
           || '<p style="margin:0;font-size:15px;line-height:1.6;color:#3E4C59;">' || rest || '</p>'
           || case when lbl is not null then
                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:14px 0 0;">'
                || '<tr><td style="background:#E0442E;border-radius:9px;">'
                || '<a href="' || url || '" style="display:inline-block;padding:11px 18px;font-size:14px;font-weight:700;color:#ffffff;text-decoration:none;">'
                || lbl || '</a></td></tr></table>'
              else '' end
           || '</td></tr></table>';
      continue;
    end if;

    esc := regexp_replace(esc, '(https?://[^[:space:]<]+[^[:space:]<.,;:!?)])',
                          '<a href="\1" style="color:#E0442E;text-decoration:underline;">\1</a>', 'g');
    esc := replace(esc, E'\n', '<br>');
    if i = n and n > 1 then
      body := body || button
           || '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">' || esc || '</p>';
      button := '';
    else
      body := body || '<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">' || esc || '</p>';
    end if;
  end loop;
  body := body || button;

  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      || '<title>Nomadwise</title></head>'
      || '<body style="margin:0;padding:0;background:#F7F8F9;">'
      || '<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:#F7F8F9;">'
      || pre || repeat('&#847; &zwnj;&nbsp;', 40) || '</div>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;">'
      || '<tr><td align="center" style="padding:28px 16px;">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">'
      || '<tr><td style="padding:0 6px 14px;' || font || '">'
      || '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>'
      || case when p_for_spaces
              then ' <span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:4px;">FOR SPACES</span>'
              else '' end
      || '</td></tr>'
      || '<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:16px;padding:30px 30px 26px;' || font || '">'
      || body
      || '</td></tr>'
      || '<tr><td style="padding:16px 6px 0;' || font || 'font-size:12px;line-height:1.6;color:#96A0AC;">'
      || 'Nomadwise, work from anywhere. Reply to this email and a person answers. '
      || '<a href="https://www.nomadwise.io" style="color:#96A0AC;">nomadwise.io</a>'
      || case when p_for_spaces
              then ' &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a>'
              else '' end
      || '</td></tr></table></td></tr></table></body></html>';
end $$;
revoke all on function public.email_html(text, text, text, boolean) from public, anon, authenticated;

-- The owner template keeps its arguments. The "Did you find a place?"
-- email (its button goes to ?found=) is to a customer, not a space.
create or replace function public.owner_email_html(
  p_text text, p_cta_label text default null, p_cta_url text default null)
returns text language sql immutable as $$
  select public.email_html(p_text, p_cta_label, p_cta_url,
                           coalesce(p_cta_url, '') not like 'https://nomadmaps.io/?found=%');
$$;

-- Enquiry emails: the ones to the customer (kind ends in _nomad) are
-- not "for spaces". Otherwise as migration 113.
create or replace function public.send_enquiry_mail(
  p_to text, p_reply_to text, p_subject text, p_text text, p_kind text,
  p_ref text, p_venue uuid, p_cc text default 'hello@nomadwise.io')
returns void language plpgsql security definer set search_path = public as $$
declare
  token text;
  req   bigint;
  payload jsonb;
begin
  select decrypted_secret into token
    from vault.decrypted_secrets where name = 'postmark_server_token' limit 1;
  if token is null or token = '' then
    raise exception 'No Postmark token in Vault yet (postmark_server_token).';
  end if;
  payload := jsonb_build_object(
    'From', 'Jonathan at Nomadwise <hello@nomadwise.io>',
    'To', p_to,
    'ReplyTo', coalesce(nullif(p_reply_to, ''), 'hello@nomadwise.io'),
    'Subject', p_subject,
    'TextBody', p_text,
    'HtmlBody', public.email_html(p_text, null, null, coalesce(p_kind, '') not like '%\_nomad'),
    'MessageStream', 'outbound',
    'Tag', p_kind);
  if coalesce(p_cc, '') <> '' and lower(p_cc) <> lower(p_to) then
    payload := payload || jsonb_build_object('Cc', p_cc);
  end if;
  select net.http_post(
    url := 'https://api.postmarkapp.com/email',
    body := payload,
    headers := jsonb_build_object(
      'X-Postmark-Server-Token', token,
      'Accept', 'application/json',
      'Content-Type', 'application/json'))
  into req;
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, provider_req, body, venue_id)
    values (p_kind, p_to, p_subject, p_ref, 'sent', req::text, p_text, p_venue);
  exception when others then null; end;
end $$;
revoke all on function public.send_enquiry_mail(text, text, text, text, text, text, uuid, text)
  from public, anon, authenticated;

-- The preview in Nomad Maps: the same template, for a space or for
-- the customer.
drop function if exists public.admin_email_preview(text);
create or replace function public.admin_email_preview(
  p_text text, p_for_spaces boolean default true)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return public.email_html(coalesce(p_text, ''), null, null, coalesce(p_for_spaces, true));
end $$;
revoke all on function public.admin_email_preview(text, boolean) from public, anon;
grant execute on function public.admin_email_preview(text, boolean) to authenticated;

-- The words: the new sign-off. Otherwise as migrations 194 and 195.
create or replace function public.enquiry_space_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  page  text;
  pitch text;
  first text;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null or e.venue_id is null then return null; end if;
  select * into v from public.venues where id = e.venue_id;

  page := case when v.webflow_slug is not null
               then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  first := nullif(nullif(split_part(trim(e.name), ' ', 1), ''), 'Someone');

  if v.listing_tier = 'verified' then
    pitch := 'Your Verified page does not have an enquiry address yet. Add one in '
          || 'your Owner account and future enquiries will reach you directly:' || E'\n'
          || 'https://nomadmaps.io/?owner';
  elsif coalesce(trim(v.listing_owner_email), '') = '' then
    pitch := 'About your listing' || E'\n'
          || v.name || ' is listed on Nomadwise free of charge, based on publicly '
          || 'available information. You can claim the page at no cost to keep your '
          || 'details up to date and add your own photos, prices and opening hours:' || E'\n'
          || 'https://nomadmaps.io/?claim='
          || coalesce(v.webflow_slug, replace(v.name, ' ', '%20'));
  else
    pitch := 'About your listing' || E'\n'
          || 'Enquiries for your page currently come to us first, and we pass them on '
          || 'to you. With a Verified listing they reach your inbox directly, and your '
          || 'page is shown with the Verified badge above other listings in '
          || coalesce(nullif(v.city, ''), 'your city') || ':' || E'\n'
          || 'https://nomadmaps.io/?owner&billing';
  end if;

  return jsonb_build_object(
    'subject', 'New enquiry for ' || v.name || ' from Nomadwise',
    'body',
      'Hi ' || v.name || ' team,' || E'\n\n'
      || 'You have a new enquiry from a remote worker who found '
      || case when page is not null then 'your page' else 'you' end
      || ' on Nomadwise' || coalesce(': ' || page, '.') || E'\n\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email || E'\n'
      || coalesce('Phone: ' || nullif(e.phone, '') || E'\n', '')
      || case e.want when 'day_pass' then 'Interested in: a day pass' || E'\n'
                     when 'desk_month' then 'Interested in: a desk for a month or longer' || E'\n'
                     when 'event' then 'Interested in: a meeting or event' || E'\n'
                     else '' end
      || coalesce('Dates: ' || nullif(e.dates, '') || E'\n', '')
      || coalesce('People: ' || e.people::text || E'\n', '')
      || 'Sent: ' || to_char(e.created_at at time zone 'utc', 'FMDD Mon YYYY') || E'\n\n'
      || 'Their message:' || E'\n'
      || coalesce(nullif(btrim(e.message), ''), '(No message)') || E'\n\n'
      || 'To reply, simply answer this email. Your reply goes directly to '
      || coalesce(first, 'them') || '.' || E'\n\n'
      || pitch || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_space_email(uuid) from public, anon, authenticated;

create or replace function public.enquiry_nomad_email(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  em    text;
  nm    text;
  first text;
  n     integer;
  one   text;
  site  text;
  lines text;
  sites boolean;
begin
  select lower(min(e.email)), min(e.name), count(*), min(v.name), min(v.website),
         string_agg('- ' || v.name
                    || coalesce(' (' || nullif(btrim(coalesce(v.website, '')), '') || ')', ''),
                    E'\n' order by v.name),
         bool_or(coalesce(btrim(v.website), '') <> '')
    into em, nm, n, one, site, lines, sites
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.id = any(p_ids);
  if coalesce(n, 0) = 0 then return null; end if;
  first := nullif(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone');

  if n = 1 then
    return jsonb_build_object(
      'to', em,
      'subject', 'Your enquiry has been sent to ' || one,
      'body',
        'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
        || 'Thank you for your enquiry on Nomadwise. We have sent it to ' || one
        || ', and their reply will come straight to this email address.' || E'\n\n'
        || case when coalesce(btrim(site), '') <> ''
                then 'If you would like to contact them yourself as well, their website is '
                     || btrim(site) || E'\n\n'
                else '' end
        || 'If you have any further questions, simply reply to this email.' || E'\n\n'
        || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
  end if;

  return jsonb_build_object(
    'to', em,
    'subject', 'Your enquiry has been sent to ' || n || ' spaces',
    'body',
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thank you for your enquiry on Nomadwise. We have sent it to these '
      || n || ' spaces:' || E'\n\n'
      || lines || E'\n\n'
      || 'Their replies will come straight to this email address.'
      || case when sites
              then ' If you would like to contact any of them yourself, their websites '
                   || 'are listed above.'
              else '' end || E'\n\n'
      || 'If you have any further questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;
revoke all on function public.enquiry_nomad_email(uuid[]) from public, anon, authenticated;

notify pgrst, 'reload schema';

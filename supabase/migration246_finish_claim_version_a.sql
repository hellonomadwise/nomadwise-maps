-- ============================================================
-- Migration 246: the "finish your claim" email, version A, and 8px corners.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 4 Nov 2026, picked version A ("One step to go") from
-- Emily's three on the "Claim reminder emails" canvas. What changes:
--
-- 1. nudge_started_claims(): new subject, words and inbox preview.
--    One button ("Finish my claim") with "Free, and takes about a
--    minute." under it; no prices; a "Not you?" line at the end; the
--    house sign-off. The link fills in the owner's email on the claim
--    page (&email=) and no longer shows as a long address in the email.
-- 2. email_html() learns three small things, used only by text that
--    asks for them, so every other email reads as before:
--      [[preview]] + a line   the inbox preview text, not shown in the body
--      [[button]] + a line    the button goes here, the line in grey under it
--      **words**              bold
-- 3. send_owner_email(): the plain-text copy turns those into plain
--    words ([[button]] becomes "Finish my claim: <address>").
-- 4. Corners: Jonathan, 4 Nov 2026, "border radius should always be 8".
--    Every designed owner email: card, buttons and panel now 8px
--    (were 16, 10, 12 and 9).
-- Safe to run twice: each step checks whether it is already done.
-- ============================================================

-- A piece of a web address, made safe (spaces, &, +, #, ?, @, %).
create or replace function public.url_part(p text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(replace(
           coalesce(p, ''),
           '%', '%25'), ' ', '%20'), '&', '%26'), '+', '%2B'),
           '#', '%23'), '?', '%3F'), '@', '%40')
$$;

-- ---------- 2 and 4: email_html ----------
do $mig$
declare
  d text;
  anchor text;
begin
  select pg_get_functiondef('public.email_html(text, text, text, boolean)'::regprocedure) into d;

  -- 4. corners
  d := replace(d, 'border-radius:16px;', 'border-radius:8px;');
  d := replace(d, 'border-radius:12px;', 'border-radius:8px;');
  d := replace(d, 'border-radius:10px;', 'border-radius:8px;');
  d := replace(d, 'border-radius:9px;',  'border-radius:8px;');

  if position('[[preview]]' in d) = 0 then
    -- [[preview]]: the inbox preview, read before the body is built.
    anchor := $a$  foreach p in array paras loop
    i := i + 1;$a$;
    if position(anchor in d) = 0 then
      raise exception 'Main loop not found in email_html';
    end if;
    d := replace(d, anchor, $b$  -- [[preview]] then a line sets the inbox preview (migration 246).
  foreach p in array paras loop
    if btrim(replace(p, E'\r', ''), E' \n\t') ~ '^\[\[preview\]\]' then
      pre := btrim(regexp_replace(btrim(replace(p, E'\r', ''), E' \n\t'), '^\[\[preview\]\][ \t]*', ''), E' \n\t');
      pre := left(regexp_replace(pre, '[[:space:]]+', ' ', 'g'), 140);
      pre := replace(replace(replace(pre, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    end if;
  end loop;

$b$ || anchor);

    -- In the body: skip [[preview]]; [[button]] places the button there.
    anchor := $a$    p := btrim(replace(p, E'\r', ''), E' \n\t');
$a$;
    if position(anchor in d) = 0 then
      raise exception 'Paragraph trim not found in email_html';
    end if;
    d := replace(d, anchor, anchor || $b$
    if p ~ '^\[\[preview\]\]' then continue; end if;
    if p ~ '^\[\[button\]\]' then
      lbl := btrim(substr(p, 11), E' \n\t');
      if button <> '' and lbl <> '' then
        body := body || replace(button, 'margin:10px 0 26px;', 'margin:8px 0 8px;')
             || '<p style="margin:0 0 22px;font-size:14px;line-height:1.5;color:#5C6773;">'
             || replace(replace(replace(lbl, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</p>';
      elsif lbl <> '' then
        body := body || '<p style="margin:0 0 16px;font-size:14px;line-height:1.5;color:#5C6773;">'
             || replace(replace(replace(lbl, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</p>';
      else
        body := body || button;
      end if;
      button := '';
      lbl := null;
      continue;
    end if;
$b$);

    -- **bold** in an ordinary paragraph.
    anchor := $a$    esc := public.email_md_links(esc);
$a$;
    if position(anchor in d) = 0 then
      raise exception 'Link step not found in email_html';
    end if;
    d := replace(d, anchor, anchor || $b$    esc := regexp_replace(esc, '\*\*([^*<\n]{1,120})\*\*', '<strong style="font-weight:700;">\1</strong>', 'g');
$b$);

    -- A small last line straight after the signature gets room above it.
    anchor := $a$body := body || button
           || '<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">' || esc || '</p>';$a$;
    if position(anchor in d) = 0 then
      raise exception 'Last paragraph step not found in email_html';
    end if;
    d := replace(d, anchor, $b$body := body || button
           || '<p style="margin:'
           || case when button = '' and right(body, 20) = 'nomadwise.io</a></p>' then '24px 0 0' else '0' end
           || ';font-size:14px;line-height:1.6;color:#5C6773;">' || esc || '</p>';$b$);
  end if;

  execute d;
end $mig$;

-- ---------- 3: send_owner_email, the plain-text copy ----------
do $mig$
declare
  d text;
  anchor text;
begin
  select pg_get_functiondef('public.send_owner_email(text, text, text, text, text, text, text)'::regprocedure) into d;
  if position('[[button]]' in d) > 0 then
    return;  -- already done
  end if;

  anchor := $a$  -- The button's address also goes into the plain text, so a reader$a$;
  if position(anchor in d) = 0 then
    raise exception 'Plain-text button step not found in send_owner_email';
  end if;
  d := replace(d, anchor, $b$  -- The designed email's markers in plain words (migration 246):
  -- no preview line, the button's words and address where [[button]]
  -- stands, bold without its stars.
  plain := regexp_replace(plain, '^[[:space:]]*\[\[preview\]\][^\n]*\n[^\n]*\n*', '');
  plain := regexp_replace(plain, '\n\n\[\[preview\]\][^\n]*\n[^\n]*', '', 'g');
  if coalesce(p_cta_url, '') <> '' then
    plain := replace(plain, '[[button]]', coalesce(p_cta_label, 'Open') || ': ' || p_cta_url);
  else
    plain := regexp_replace(plain, '\[\[button\]\][ \t]*\n?', '', 'g');
  end if;
  plain := regexp_replace(plain, '\*\*([^*\n]{1,120})\*\*', '\1', 'g');

$b$ || anchor);

  anchor := $a$position(p_cta_url in coalesce(p_text, ''))$a$;
  if position(anchor in d) = 0 then
    raise exception 'Button address check not found in send_owner_email';
  end if;
  d := replace(d, anchor, $a$position(p_cta_url in coalesce(plain, ''))$a$);

  execute d;
end $mig$;

-- ---------- 1: the email itself ----------
create or replace function public.nudge_started_claims()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  c       record;
  n       integer := 0;
  space   text;
  kind_of text;
  first   text;
  link    text;
  body    text;
begin
  for c in
    select * from public.listing_claims
     where status = 'started'
       and nudged_at is null
       and coalesce(owner_email, '') <> ''
       and created_at between now() - interval '3 days' and now() - interval '20 hours'
       and not exists (select 1 from public.owner_emails e
                        where e.to_email = lower(listing_claims.owner_email)
                          and e.kind = 'finish_claim')
  loop
    space := coalesce(nullif(c.space_name, ''),
                      (select name from public.venues where id = c.venue_id),
                      'your space');
    kind_of := public.space_kind(coalesce(
                 (select type from public.venues where id = c.venue_id), c.space_type));
    first := coalesce(nullif(split_part(trim(coalesce(c.owner_name, '')), ' ', 1), ''), 'there');
    link  := 'https://nomadmaps.io/?claim=' || public.url_part(space)
          || '&email=' || public.url_part(lower(trim(c.owner_email)));
    body  := '[[preview]]' || E'\n'
          || 'It''s free and takes about a minute. Here''s the link to finish.' || E'\n\n'
          || 'Hi ' || first || ',' || E'\n\n'
          || 'You started claiming **' || space || '** on Nomadwise. There''s just one step to go.' || E'\n\n'
          || 'Once it''s yours, you can add your own photos, keep your opening hours and '
          || 'prices up to date, and make sure the people who find you see your '
          || kind_of || ' as it really is.' || E'\n\n'
          || '[[button]]' || E'\n'
          || 'Free, and takes about a minute.' || E'\n\n'
          || 'If something got in the way, just reply to this email and tell me. '
          || 'I read every one.' || E'\n\n'
          || 'Kind regards,' || E'\n' || 'Jonathan' || E'\n' || 'Co-founder, Nomadwise' || E'\n\n'
          || 'You''re getting this because someone started claiming ' || space
          || ' on nomadwise.io with this email address. Not you? Ignore this email '
          || 'and nothing will change.';
    perform public.send_owner_email(c.owner_email,
                                    'One more step to claim ' || space,
                                    body, 'finish_claim', c.id::text,
                                    'Finish my claim', link);
    update public.listing_claims set nudged_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

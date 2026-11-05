-- ============================================================
-- Migration 259: owner emails can go out through the Postmark templates.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Nov 2026, after approving all 19 test pairs: "can you
-- switch all 19 over to the new postmark templates now".
--
-- How it works:
--  * Each email's code still writes today's subject and text (kept in
--    owner_emails as the permanent record of what was sent), and now
--    also hands over the facts the Postmark template needs (the
--    "model") with pm_set_model just before it sends.
--  * send_owner_email / send_owner_email_reply_to take that model. When
--    the email's row in email_templates is switched on (live = true),
--    the email goes to Postmark's /email/withTemplate with the template,
--    on that template's stream. Otherwise, or if anything about the
--    model is missing, it goes out exactly as before.
--  * So the way back for any email is: update email_templates set
--    live = false where alias = '...'.
--  * owner_emails_retry re-sends a template email to /email/withTemplate.
--
-- This migration connects emails 01-13 (claims, finish claim, page live,
-- changes, Premium ended, sign-in reminders, chat) and switches them on
-- (see the end), after checking each renders the same as today.
-- ============================================================

-- ---------- the hand-over ----------
create or replace function public.pm_set_model(p_kind text, p_alias text, p_model jsonb) returns void
language sql as $$
  select set_config('nomadwise.pm_kind',  coalesce(p_kind, ''), true),
         set_config('nomadwise.pm_alias', coalesce(p_alias, ''), true),
         set_config('nomadwise.pm_model', coalesce(p_model::text, ''), true);
$$;

-- The inbox preview line: the template's own example preview, with the
-- example's names swapped for this email's.
create or replace function public.pm_preview(p_alias text, p_model jsonb) returns text
language plpgsql stable set search_path to 'public' as $$
declare
  tm jsonb;
  p  text;
  k  text;
begin
  select test_model into tm from public.email_templates where alias = p_alias;
  p := coalesce(tm ->> 'preview', '');
  foreach k in array array['space_name', 'space_names', 'space_kind', 'from_name', 'greeting_name', 'first_name'] loop
    if coalesce(tm ->> k, '') <> '' and p_model ? k then
      p := replace(p, tm ->> k, coalesce(p_model ->> k, ''));
    end if;
  end loop;
  return p;
end $$;

-- Takes (and always clears) the model handed over for this send. Gives
-- back the template only when it is switched on and the model was
-- meant for this kind of email.
create or replace function public.pm_take_model(p_kind text)
returns table(alias text, stream text, model jsonb)
language plpgsql set search_path to 'public' as $$
declare
  k  text := coalesce(current_setting('nomadwise.pm_kind', true), '');
  a  text := coalesce(current_setting('nomadwise.pm_alias', true), '');
  m  text := coalesce(current_setting('nomadwise.pm_model', true), '');
  t  public.email_templates%rowtype;
  mj jsonb;
begin
  perform public.pm_set_model(null, null, null);
  if k = '' or a = '' or m = '' or k <> coalesce(p_kind, '') then
    return query select null::text, null::text, null::jsonb; return;
  end if;
  select * into t from public.email_templates e where e.alias = a and e.live;
  if not found then
    return query select null::text, null::text, null::jsonb; return;
  end if;
  mj := m::jsonb;
  if coalesce(mj ->> 'preview', '') = '' then
    mj := mj || jsonb_build_object('preview', public.pm_preview(a, mj));
  end if;
  mj := jsonb_build_object('for_spaces', t.for_spaces) || mj;
  return query select t.alias, t.stream, mj;
exception when others then
  return query select null::text, null::text, null::jsonb;
end $$;

-- Text written by a person, safe to put in the HTML of an email.
create or replace function public.pm_html_text(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''),
         '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), E'\n', '<br>')
$$;

-- Checks emails sent through a template since a moment: renders the
-- template with the model that was sent and compares it line by line
-- with today's text kept in owner_emails. Used before switching an
-- email on, and to check the first real sends.
create or replace function public.pm_check_sent(p_since timestamptz)
returns table(kind text, to_email text, result text, detail text)
language plpgsql security definer set search_path to 'public' as $$
declare
  r record; t record; rj jsonb; tok text := public.pm_token();
  oldl text[]; newl text[]; a text[]; b text[]; pat text;
begin
  for r in select o.* from public.owner_emails o where o.created_at >= p_since order by o.created_at, o.id loop
    kind := r.kind; to_email := r.to_email;
    if r.payload is null or not (r.payload ? 'TemplateAlias') then
      result := 'old path'; detail := coalesce(r.status, '') || ' ' || coalesce(r.error, '');
      return next; continue;
    end if;
    select * into t from public.email_templates e where e.alias = r.payload->>'TemplateAlias';
    rj := (extensions.http(('POST','https://api.postmarkapp.com/templates/validate',
      array[extensions.http_header('X-Postmark-Server-Token', tok), extensions.http_header('Accept','application/json')],
      'application/json',
      jsonb_build_object('Subject', t.subject, 'HtmlBody', t.html_body, 'TextBody', t.text_body,
        'TestRenderModel', r.payload->'TemplateModel', 'LayoutTemplate', 'nomadwise-layout', 'TemplateType', 'Standard')::text
      )::extensions.http_request)).content::jsonb;
    pat := '^[A-Z][A-Za-z ]{1,30}: ' || regexp_replace(coalesce(r.cta_url, '#none#'), '([.?*+^$()\[\]{}|\\])', '\\\1', 'g') || '$';
    select array_agg(btrim(l) order by btrim(l)) into oldl from regexp_split_to_table(r.body, E'\n') l
     where btrim(l) <> '' and btrim(l) !~ pat;
    select array_agg(btrim(l) order by btrim(l)) into newl from regexp_split_to_table(rj#>>'{TextBody,RenderedContent}', E'\n') l
     where btrim(l) <> '' and btrim(l) <> '--' and btrim(l) not like 'Nomadwise, work from anywhere.%' and btrim(l) !~ pat;
    select array_agg(x) into a from unnest(oldl) x where x <> all(coalesce(newl, '{}'));
    select array_agg(x) into b from unnest(newl) x where x <> all(coalesce(oldl, '{}'));
    if (rj#>>'{Subject,RenderedContent}') = r.subject and a is null and b is null then
      result := 'match'; detail := r.payload->>'TemplateAlias' || ' [' || (r.payload->>'MessageStream') || ']';
    else
      result := 'DIFF';
      detail := case when (rj#>>'{Subject,RenderedContent}') is distinct from r.subject
                     then 'subject old: ' || r.subject || ' | new: ' || coalesce(rj#>>'{Subject,RenderedContent}', '?') || ' ' else '' end
             || coalesce('only old: ' || array_to_string(a, ' / ') || ' ', '')
             || coalesce('only new: ' || array_to_string(b, ' / '), '');
    end if;
    return next;
  end loop;
end $$;
revoke all on function public.pm_check_sent(timestamptz) from public, anon, authenticated;

-- Changes one function's code in place; skips it when already done.
create or replace function public.pm_patch_fn(p_fn text, p_anchor text, p_new text, p_marker text)
returns text language plpgsql set search_path to 'public' as $$
declare d text;
begin
  select pg_get_functiondef(to_regprocedure(p_fn)) into d;
  if d is null then raise exception 'pm_patch_fn: no function %', p_fn; end if;
  if position(p_marker in d) > 0 then return 'already'; end if;
  if position(p_anchor in d) = 0 then raise exception 'pm_patch_fn: anchor not found in %', p_fn; end if;
  execute replace(d, p_anchor, p_new);
  return 'patched';
end $$;
revoke all on function public.pm_patch_fn(text, text, text, text) from public, anon, authenticated;

-- ---------- the two owner senders ----------
do $$
declare f text;
begin
  foreach f in array array['public.send_owner_email(text,text,text,text,text,text,text)',
                           'public.send_owner_email_reply_to(text,text,text,text,text,text,text,text)'] loop
    perform public.pm_patch_fn(f,
      E'  vid   uuid;\nbegin\n  if dest = '''' or position(''@'' in dest) < 2 then return; end if;',
      E'  vid   uuid;\n  pmt   record;\n  purl  text := ''https://api.postmarkapp.com/email'';\nbegin\n'
      || E'  -- the Postmark template for this email, when it is switched on (migration 259)\n'
      || E'  select * into pmt from public.pm_take_model(p_kind);\n'
      || E'  if dest = '''' or position(''@'' in dest) < 2 then return; end if;',
      'pm_take_model');
    perform public.pm_patch_fn(f,
      E'  select net.http_post(\n    url := ''https://api.postmarkapp.com/email'',\n    body := pl,',
      E'  if pmt.alias is not null then\n'
      || E'    pl := (pl - ''Subject'' - ''TextBody'' - ''HtmlBody'')\n'
      || E'          || jsonb_build_object(''TemplateAlias'', pmt.alias, ''TemplateModel'', pmt.model,\n'
      || E'                                ''MessageStream'', pmt.stream);\n'
      || E'    purl := ''https://api.postmarkapp.com/email/withTemplate'';\n'
      || E'  end if;\n\n'
      || E'  select net.http_post(\n    url := purl,\n    body := pl,',
      'url := purl');
  end loop;

  perform public.pm_patch_fn('public.owner_emails_retry()',
    E'      url := ''https://api.postmarkapp.com/email'',\n      body := e.payload,',
    E'      url := case when e.payload ? ''TemplateAlias''\n'
    || E'                  then ''https://api.postmarkapp.com/email/withTemplate''\n'
    || E'                  else ''https://api.postmarkapp.com/email'' end,\n      body := e.payload,',
    'withTemplate');
end $$;

-- ---------- 01-05: claim emails ----------
select public.pm_patch_fn('public.claim_emails()',
  E'  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);',
  E'  begin\n'
  || E'    perform public.pm_set_model(kind,\n'
  || E'      case kind when ''claim_received'' then ''claim-received'' when ''payment_received'' then ''payment-received''\n'
  || E'                when ''approved_verified'' then ''claim-approved-premium'' when ''approved_free'' then ''claim-approved-free''\n'
  || E'                when ''rejected'' then ''claim-rejected'' end,\n'
  || E'      jsonb_build_object(''first_name'', first, ''space_name'', space, ''space_kind'', kind_of,\n'
  || E'        ''page_url'', coalesce(url, ''''),\n'
  || E'        ''has_page'', url is not null and not (kind in (''claim_received'', ''payment_received'') and coalesce(new.is_new_space, false)),\n'
  || E'        ''no_page_yet'', url is null and not (kind in (''claim_received'', ''payment_received'') and coalesce(new.is_new_space, false)),\n'
  || E'        ''owner_url'', ''https://nomadmaps.io/owner'', ''cta_url'', coalesce(cta_url, ''https://nomadmaps.io/owner''),\n'
  || E'        ''is_new_space'', coalesce(new.is_new_space, false),\n'
  || E'        ''enquiry_address'', coalesce(nullif(new.enquiry_email, ''''), new.owner_email),\n'
  || E'        ''price_words'', case when kind = ''approved_free'' then public.verified_price_words(coalesce(\n'
  || E'                           (select country from public.venues where id = new.venue_id), new.space_country)) else '''' end,\n'
  || E'        ''was_paid'', coalesce(tg_op = ''UPDATE'' and kind = ''rejected'' and old.status = ''awaiting_approval'', false)));\n'
  || E'  exception when others then null; end;\n'
  || E'  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);',
  'pm_set_model');

-- ---------- 06: finish your claim ----------
select public.pm_patch_fn('public.nudge_started_claims()',
  E'    perform public.send_owner_email(c.owner_email,\n                                    ''One more step to claim '' || space,',
  E'    begin\n'
  || E'      perform public.pm_set_model(''finish_claim'', ''finish-claim'',\n'
  || E'        jsonb_build_object(''first_name'', first, ''space_name'', space, ''space_kind'', kind_of,\n'
  || E'          ''cta_url'', link, ''owner_url'', ''https://nomadmaps.io/owner'',\n'
  || E'          ''page_url'', '''', ''has_page'', false, ''no_page_yet'', true,\n'
  || E'          ''preview'', ''It''''s free and takes about a minute. Here''''s the link to finish.''));\n'
  || E'    exception when others then null; end;\n'
  || E'    perform public.send_owner_email(c.owner_email,\n                                    ''One more step to claim '' || space,',
  'pm_set_model');

-- ---------- 07: page live ----------
select public.pm_patch_fn('public.page_live_email()',
  E'  perform public.send_owner_email(new.listing_owner_email,\n                                  new.name || '' is live on Nomadwise'',',
  E'  begin\n'
  || E'    perform public.pm_set_model(''page_live'', ''page-live'',\n'
  || E'      jsonb_build_object(''first_name'', first, ''space_name'', new.name,\n'
  || E'        ''space_kind'', public.space_kind(new.type),\n'
  || E'        ''page_url'', url, ''has_page'', true, ''no_page_yet'', false,\n'
  || E'        ''owner_url'', ''https://nomadmaps.io/owner'', ''cta_url'', url,\n'
  || E'        ''is_premium'', new.listing_tier = ''verified'',\n'
  || E'        ''is_free_asked'', new.listing_tier is distinct from ''verified'' and asked,\n'
  || E'        ''is_free_public'', new.listing_tier is distinct from ''verified'' and not asked,\n'
  || E'        ''enquiry_address'', coalesce(nullif(new.listing_enquiry_email, ''''), new.listing_owner_email)));\n'
  || E'  exception when others then null; end;\n'
  || E'  perform public.send_owner_email(new.listing_owner_email,\n                                  new.name || '' is live on Nomadwise'',',
  'pm_set_model');

-- ---------- 08-09: changes on the page / sent back ----------
select public.pm_patch_fn('public.owner_draft_emails()',
  E'  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);',
  E'  begin\n'
  || E'    perform public.pm_set_model(kind,\n'
  || E'      case kind when ''changes_live'' then ''changes-live'' when ''changes_back'' then ''changes-returned'' end,\n'
  || E'      jsonb_build_object(''first_name'', '''', ''space_name'', space, ''space_kind'', '''',\n'
  || E'        ''page_url'', coalesce(url, ''''), ''has_page'', url is not null, ''no_page_yet'', url is null,\n'
  || E'        ''owner_url'', ''https://nomadmaps.io/owner'', ''cta_url'', cta_url,\n'
  || E'        ''owner_email'', em, ''owner_signin_url'', acct,\n'
  || E'        ''is_gmail'', (em like ''%@gmail.com'' or em like ''%@googlemail.com''),\n'
  || E'        ''review_note'', coalesce(new.review_note, '''')));\n'
  || E'  exception when others then null; end;\n'
  || E'  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);',
  'pm_set_model');

-- ---------- 10: Premium ended ----------
select public.pm_patch_fn('public.plan_ended(uuid,text)',
  E'  perform public.send_owner_email(v.listing_owner_email,\n                                  ''Your Premium plan for '' || v.name || '' has ended'',',
  E'  begin\n'
  || E'    perform public.pm_set_model(''plan_ended'', ''premium-ended'',\n'
  || E'      jsonb_build_object(''first_name'', first, ''space_name'', v.name,\n'
  || E'        ''space_kind'', public.space_kind(v.type),\n'
  || E'        ''page_url'', coalesce(url, ''''), ''has_page'', url is not null, ''no_page_yet'', url is null,\n'
  || E'        ''owner_url'', ''https://nomadmaps.io/owner'', ''cta_url'', ''https://nomadmaps.io/owner''));\n'
  || E'  exception when others then null; end;\n'
  || E'  perform public.send_owner_email(v.listing_owner_email,\n                                  ''Your Premium plan for '' || v.name || '' has ended'',',
  'pm_set_model');

-- ---------- 11-12: sign-in reminders ----------
select public.pm_patch_fn('public.signin_reminders_run()',
  E'      perform public.send_owner_email(\n        r.owner_email, t.subject, t.body, ''signin_reminder_'' || r.next_step,',
  E'      begin\n'
  || E'        perform public.pm_set_model(''signin_reminder_'' || r.next_step, ''signin-reminder-'' || r.next_step,\n'
  || E'          jsonb_build_object(''first_name'', first, ''space_name'', coalesce(r.name, ''your space''),\n'
  || E'            ''space_kind'', '''',\n'
  || E'            ''page_url'', coalesce(public.owner_page_url(r.venue_id), ''''),\n'
  || E'            ''has_page'', public.owner_page_url(r.venue_id) is not null,\n'
  || E'            ''no_page_yet'', public.owner_page_url(r.venue_id) is null,\n'
  || E'            ''owner_url'', ''https://nomadmaps.io/owner'', ''cta_url'', ''https://nomadmaps.io/owner''));\n'
  || E'      exception when others then null; end;\n'
  || E'      perform public.send_owner_email(\n        r.owner_email, t.subject, t.body, ''signin_reminder_'' || r.next_step,',
  'pm_set_model');

-- ---------- 13: chat message from the team ----------
-- Only when the message has an author (the template's subject starts
-- with their name); otherwise it goes out as before.
select public.pm_patch_fn('public.chat_email_sync()',
  E'        if addr is not null then\n          perform public.send_owner_email_reply_to(',
  E'        begin\n'
  || E'          if who is not null then\n'
  || E'            perform public.pm_set_model(''chat'', ''chat-message'',\n'
  || E'              jsonb_build_object(''from_name'', who, ''space_name'', coalesce(r.name, ''your space''),\n'
  || E'                ''first_name'', '''', ''space_kind'', '''',\n'
  || E'                ''message'', case when char_length(words) > 6000\n'
  || E'                                then left(words, 6000) || E''\\n\\n'' || ''(The rest is in the chat.)'' else words end,\n'
  || E'                ''message_html'', public.pm_html_text(case when char_length(words) > 6000\n'
  || E'                                then left(words, 6000) || E''\\n\\n'' || ''(The rest is in the chat.)'' else words end),\n'
  || E'                ''chat_url'', ''https://nomadmaps.io/owner?chat='' || r.venue_id::text,\n'
  || E'                ''cta_url'', ''https://nomadmaps.io/owner?chat='' || r.venue_id::text,\n'
  || E'                ''owner_url'', ''https://nomadmaps.io/owner'',\n'
  || E'                ''page_url'', '''', ''has_page'', false, ''no_page_yet'', true,\n'
  || E'                ''reply_by_email'', addr is not null));\n'
  || E'          end if;\n'
  || E'        exception when others then null; end;\n'
  || E'        if addr is not null then\n          perform public.send_owner_email_reply_to(',
  'pm_set_model');

-- Switched on 5 Nov 2026 after pm_check_sent matched every case
-- (20 scenarios, including a new space, a paid then rejected claim, a
-- Gmail owner, a Premium page and a chat with special characters):
update public.email_templates set live = true, updated_at = now()
 where alias in ('claim-received','payment-received','claim-approved-premium','claim-approved-free','claim-rejected',
                 'finish-claim','page-live','changes-live','changes-returned','premium-ended',
                 'signin-reminder-1','signin-reminder-2','chat-message')
   and not live;

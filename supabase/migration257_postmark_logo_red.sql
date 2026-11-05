-- ============================================================
-- Migration 257: Postmark templates get the Nomadwise logo and red.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Nov 2026, comparing test pair 05: "for the current there
-- is the nomadwise logo, whereas the new ones dont. (they should have
-- the nomadwise logo".
--
-- The Postmark layout (migration 253) was built from the email design
-- before migration 247 changed it, so it still had the "nomadwise" word
-- in the old orange #E0442E instead of the logo image, and its buttons
-- and links used #E0442E too. This brings the layout, the helpers and
-- the stored templates in line with today's emails: the logo from
-- https://nomadmaps.io/email/nomadwise-logo.png (150x44, alt
-- "nomadwise.io"), "FOR SPACES" lined up beside it, and Nomadwise red
-- #FF444F everywhere. Then it pushes the layout and all templates to
-- Postmark again (they stay "[Not live yet]" until approved).
--
-- It also fixes the "replace what is in Postmark" path of
-- pm_layout_push / pm_template_push: it called net.http_request, which
-- this database's pg_net does not have (the first try of this migration
-- failed on it). Updates now go straight to Postmark with a PUT through
-- the http extension, and any error is kept in push_error.
-- ============================================================

do $$
declare
  d text;
  f text;
begin
  -- layout: logo instead of the word, FOR SPACES aligned like email_html
  select pg_get_functiondef('public.pm_layout_html()'::regprocedure) into d;
  d := replace(d,
    '<span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span>',
    '<img src="https://nomadmaps.io/email/nomadwise-logo.png" width="150" height="44" alt="nomadwise.io" style="display:inline-block;vertical-align:middle;border:0;outline:none;text-decoration:none;width:150px;height:44px;color:#FF444F;font-size:20px;font-weight:800;">');
  d := replace(d,
    'letter-spacing:1.2px;margin-left:4px;">FOR SPACES',
    'letter-spacing:1.2px;margin-left:6px;vertical-align:middle;">FOR SPACES');
  d := replace(d, '#E0442E', '#FF444F');
  if position('nomadwise-logo.png' in d) = 0 or position('vertical-align:middle;">FOR SPACES' in d) = 0 then
    raise exception 'pm_layout_html: header not found';
  end if;
  execute d;

  -- helpers: links, button, signatures in Nomadwise red
  foreach f in array array['public.pm_a(text)', 'public.pm_aw(text,text)', 'public.pm_btn(text,text,text)',
                           'public.pm_sig_short()', 'public.pm_sig(text)'] loop
    if to_regprocedure(f) is not null then
      select pg_get_functiondef(to_regprocedure(f)) into d;
      if position('#E0442E' in d) > 0 then
        execute replace(d, '#E0442E', '#FF444F');
      end if;
    end if;
  end loop;
end $$;

-- updates to Postmark: synchronous PUT (pg_net has no PUT here)
create or replace function public.pm_put(p_path text, p_body jsonb) returns int
language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  select * into r from extensions.http(('PUT', 'https://api.postmarkapp.com/' || p_path,
    array[extensions.http_header('X-Postmark-Server-Token', public.pm_token()),
          extensions.http_header('Accept', 'application/json')],
    'application/json', p_body::text)::extensions.http_request);
  if r.status not between 200 and 299 then
    raise warning 'Postmark PUT % failed: % %', p_path, r.status, left(r.content, 300);
  end if;
  return r.status;
end $$;
revoke all on function public.pm_put(text, jsonb) from public, anon, authenticated;

create or replace function public.pm_layout_push(p_force boolean default false) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare
  req bigint;
  body jsonb := jsonb_build_object(
    'Name', 'Nomadwise email layout', 'Alias', 'nomadwise-layout', 'TemplateType', 'Layout',
    'HtmlBody', public.pm_layout_html(), 'TextBody', public.pm_layout_text());
begin
  if p_force then
    return public.pm_put('templates/nomadwise-layout', body);
  end if;
  select net.http_post(
    url := 'https://api.postmarkapp.com/templates', body := body,
    headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                  'Accept', 'application/json', 'Content-Type', 'application/json'))
    into req;
  return req;
end $$;

create or replace function public.pm_template_push(p_alias text, p_force boolean default false) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare
  t   public.email_templates%rowtype;
  req bigint;
  st  int;
  body jsonb;
begin
  select * into t from public.email_templates where alias = p_alias;
  if not found then raise exception 'No template %', p_alias; end if;
  if t.postmark_id is not null and not p_force then return null; end if;
  body := jsonb_build_object(
    'Name', case when t.live then t.name else '[Not live yet] ' || t.name end,
    'Alias', t.alias, 'TemplateType', 'Standard', 'LayoutTemplate', 'nomadwise-layout',
    'Subject', t.subject, 'HtmlBody', t.html_body, 'TextBody', t.text_body);
  if t.postmark_id is null then
    select net.http_post(url := 'https://api.postmarkapp.com/templates', body := body,
      headers := jsonb_build_object('X-Postmark-Server-Token', public.pm_token(),
                                    'Accept', 'application/json', 'Content-Type', 'application/json'))
      into req;
    update public.email_templates set push_req = req, pushed_at = now(), push_error = null where alias = p_alias;
    return req;
  end if;
  st := public.pm_put('templates/' || t.alias, body);
  update public.email_templates
     set push_req = null, pushed_at = now(),
         push_error = case when st between 200 and 299 then null else 'PUT status ' || st end
   where alias = p_alias;
  return st;
end $$;

-- stored templates (built from the helpers when seeded)
update public.email_templates
   set html_body = replace(html_body, '#E0442E', '#FF444F'),
       updated_at = now()
 where position('#E0442E' in html_body) > 0;

-- push the corrected layout and every template to Postmark again
select public.pm_layout_push(true);
select public.pm_template_push(alias, true) from public.email_templates order by sort;

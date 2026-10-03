-- ============================================================
-- Migration 123: Outreach templates a founder can make and change.
-- (Applied automatically by the build; nothing to paste.)
--
-- The five templates could have their words changed but not their
-- names, and there was no way to add one or remove one (Jonathan,
-- 3 Oct 2026). Now:
--   * admin_outreach_upsert_template() makes a new template or saves
--     an existing one, name included, and refuses a placeholder it
--     does not know (a typo like {spacename} would otherwise only be
--     caught when an email is about to go);
--   * admin_outreach_delete_template() removes one (never the last);
--   * the subject line takes {first_name}, {name} and {city} as well
--     as {space}.
-- Emails already sent keep the name of the template they used.
-- ============================================================

-- The first version saved without checking placeholders; nothing calls
-- it any more.
drop function if exists public.admin_outreach_save_template(text, text, text);

-- '' when every placeholder is one we fill in, otherwise the first
-- problem in words. The subject takes the four word placeholders only.
create or replace function public.outreach_template_problem(p_subject text, p_body text)
returns text language plpgsql immutable as $$
declare
  bad text;
begin
  select string_agg(distinct '{' || m[1] || '}', ', ') into bad
    from regexp_matches(coalesce(p_body, ''), '\{([A-Za-z_]+)\}', 'g') m
   where m[1] <> all (array['first_name', 'name', 'space', 'city', 'page_link',
                            'claim_link', 'price_words', 'unsubscribe_link', 'signoff']);
  if bad is not null then
    return 'The email has a placeholder we do not fill in: ' || bad
        || '. Pick one from the list above the email.';
  end if;
  select string_agg(distinct '{' || m[1] || '}', ', ') into bad
    from regexp_matches(coalesce(p_subject, ''), '\{([A-Za-z_]+)\}', 'g') m
   where m[1] <> all (array['first_name', 'name', 'space', 'city']);
  if bad is not null then
    return 'The subject can only use {space}, {city}, {first_name} or {name}, not ' || bad || '.';
  end if;
  return '';
end $$;

create or replace function public.admin_outreach_upsert_template(
  p_key text, p_name text, p_subject text, p_body text)
returns text language plpgsql security definer set search_path = public as $$
declare
  k   text := nullif(trim(coalesce(p_key, '')), '');
  why text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'Give the template a name.';
  end if;
  if nullif(trim(coalesce(p_subject, '')), '') is null
     or nullif(trim(coalesce(p_body, '')), '') is null then
    raise exception 'Subject and email are both needed.';
  end if;
  why := public.outreach_template_problem(p_subject, p_body);
  if why <> '' then raise exception '%', why; end if;

  if k is null then
    k := 'custom_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    insert into public.outreach_templates (key, name, subject, body, stream, sort)
    values (k, left(trim(p_name), 80), trim(p_subject), p_body, 'outbound',
            coalesce((select max(sort) from public.outreach_templates), 0) + 10);
  else
    update public.outreach_templates
       set name = left(trim(p_name), 80), subject = trim(p_subject),
           body = p_body, updated_at = now()
     where key = k;
    if not found then raise exception 'That template no longer exists.'; end if;
  end if;
  return k;
end $$;
revoke all on function public.admin_outreach_upsert_template(text, text, text, text) from public, anon;
grant execute on function public.admin_outreach_upsert_template(text, text, text, text) to authenticated;

create or replace function public.admin_outreach_delete_template(p_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if (select count(*) from public.outreach_templates) <= 1 then
    raise exception 'Keep at least one template.';
  end if;
  delete from public.outreach_templates where key = p_key;
end $$;
revoke all on function public.admin_outreach_delete_template(text) from public, anon;
grant execute on function public.admin_outreach_delete_template(text) to authenticated;

-- A template with the contact's details filled in: {subject, body}.
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
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
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
  body := replace(body, '{signoff}', E'Jonathan\nNomadwise, https://www.nomadwise.io');
  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream,
                            'unsubscribe_link', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

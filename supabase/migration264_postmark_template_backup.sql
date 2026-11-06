-- ============================================================
-- Migration 264: nightly backup of the email templates in Postmark.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "ok, build the nightly backup".
--
-- Since 5-6 Nov the 22 owner and enquiry emails go out through their
-- Postmark templates, so an edit in Postmark changes what people get.
-- Every night at 02:50 UTC this:
--  * reads every template (and the shared layout) from Postmark,
--  * keeps a new version in email_template_versions whenever it differs
--    from the last one kept (so every edit can be seen and undone),
--  * brings email_templates in line with Postmark, so a later push from
--    here never overwrites an edit made in Postmark,
--  * tells the founders' phones which templates changed.
--
-- To undo an edit: select public.pm_template_restore(<version id>);
-- puts that version back in Postmark (and in email_templates).
-- ============================================================

create table if not exists public.email_template_versions (
  id         bigserial primary key,
  alias      text not null,
  name       text,
  subject    text,
  html_body  text,
  text_body  text,
  source     text not null default 'postmark nightly',
  saved_at   timestamptz not null default now()
);
create index if not exists email_template_versions_alias on public.email_template_versions (alias, saved_at desc);
alter table public.email_template_versions enable row level security;
drop policy if exists email_template_versions_admin on public.email_template_versions;
create policy email_template_versions_admin on public.email_template_versions
  for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.pm_templates_backup() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  tok     text := public.pm_token();
  a       text;
  r       record;
  j       jsonb;
  last    public.email_template_versions%rowtype;
  changed text[] := '{}';
  failed  text[] := '{}';
  n       int := 0;
begin
  for a in select 'nomadwise-layout' union all (select alias from public.email_templates order by sort) loop
    begin
      select * into r from extensions.http(('GET', 'https://api.postmarkapp.com/templates/' || a,
        array[extensions.http_header('X-Postmark-Server-Token', tok), extensions.http_header('Accept', 'application/json')],
        null, null)::extensions.http_request);
      if r.status <> 200 then
        failed := failed || (a || ' (' || r.status || ')');
        continue;
      end if;
      j := r.content::jsonb;
      n := n + 1;
      select * into last from public.email_template_versions v where v.alias = a order by v.saved_at desc, v.id desc limit 1;
      if last.id is null
         or last.subject is distinct from (j ->> 'Subject')
         or last.html_body is distinct from (j ->> 'HtmlBody')
         or last.text_body is distinct from (j ->> 'TextBody') then
        insert into public.email_template_versions (alias, name, subject, html_body, text_body, source)
        values (a, j ->> 'Name', j ->> 'Subject', j ->> 'HtmlBody', j ->> 'TextBody',
                case when last.id is null then 'first backup' else 'postmark nightly' end);
        if last.id is not null then changed := changed || a; end if;
      end if;
      -- keep the copy here the same as Postmark (Postmark is where edits are made)
      update public.email_templates t
         set subject = j ->> 'Subject', html_body = j ->> 'HtmlBody', text_body = j ->> 'TextBody',
             updated_at = now()
       where t.alias = a
         and (t.subject is distinct from (j ->> 'Subject') or t.html_body is distinct from (j ->> 'HtmlBody')
              or t.text_body is distinct from (j ->> 'TextBody'));
    exception when others then
      failed := failed || (a || ' (' || left(sqlerrm, 80) || ')');
    end;
  end loop;

  if array_length(changed, 1) > 0 or array_length(failed, 1) > 0 then
    begin
      perform public.notify_phone(
        'Email templates: ' || coalesce(array_length(changed, 1), 0) || ' changed in Postmark',
        case when array_length(changed, 1) > 0 then 'Changed: ' || array_to_string(changed, ', ') || '. A copy of each version is kept. ' else '' end
        || case when array_length(failed, 1) > 0 then 'Could not read: ' || array_to_string(failed, ', ') || '.' else '' end,
        'envelope');
    exception when others then null; end;
  end if;
  return jsonb_build_object('read', n, 'changed', to_jsonb(changed), 'failed', to_jsonb(failed));
end $$;
revoke all on function public.pm_templates_backup() from public, anon, authenticated;

-- Puts a kept version back in Postmark and in email_templates.
create or replace function public.pm_template_restore(p_version bigint) returns int
language plpgsql security definer set search_path to 'public' as $$
declare
  v  public.email_template_versions%rowtype;
  st int;
begin
  select * into v from public.email_template_versions where id = p_version;
  if not found then raise exception 'No kept version %', p_version; end if;
  if v.alias = 'nomadwise-layout' then
    st := public.pm_put('templates/nomadwise-layout', jsonb_build_object(
      'Name', coalesce(v.name, 'Nomadwise email layout'), 'Alias', 'nomadwise-layout',
      'HtmlBody', v.html_body, 'TextBody', v.text_body));
  else
    update public.email_templates set subject = v.subject, html_body = v.html_body, text_body = v.text_body,
           updated_at = now()
     where alias = v.alias;
    st := public.pm_put('templates/' || v.alias, jsonb_build_object(
      'Name', v.name, 'Alias', v.alias, 'Subject', v.subject, 'HtmlBody', v.html_body, 'TextBody', v.text_body));
  end if;
  insert into public.email_template_versions (alias, name, subject, html_body, text_body, source)
  values (v.alias, v.name, v.subject, v.html_body, v.text_body, 'restored from version ' || p_version);
  return st;
end $$;
revoke all on function public.pm_template_restore(bigint) from public, anon, authenticated;

select cron.unschedule('email-templates-backup')
 where exists (select 1 from cron.job where jobname = 'email-templates-backup');
select cron.schedule('email-templates-backup', '50 2 * * *', 'select public.pm_templates_backup()');

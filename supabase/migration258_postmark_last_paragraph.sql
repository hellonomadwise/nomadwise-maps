-- ============================================================
-- Migration 258: no extra space under the last line of a Postmark email.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 5 Nov 2026, test pair 18: the new version had more space
-- between the last line ("Nomadwise, <link>") and the bottom of the
-- white box than the current one. Today's emails always give the last
-- paragraph no bottom margin; six templates still had 16px there:
-- enquiry-premium-direct, signin-reminder-1 and -2, chat-message (both
-- endings), enquiry-unreachable-nomad and site-chat-reply.
--
-- A trigger now sets the last paragraph's bottom margin to 0 whenever a
-- template is saved, so a re-seed or an edit cannot bring it back.
-- ============================================================

create or replace function public.pm_fix_last_margin() returns trigger
language plpgsql as $$
begin
  if new.alias = 'chat-message' then
    new.html_body := replace(new.html_body,
      '{{#reply_by_email}}<p style="margin:0 0 16px;', '{{#reply_by_email}}<p style="margin:0;');
  end if;
  new.html_body := regexp_replace(new.html_body,
    '<p style="margin:0 0 16px;((?:(?!<p ).)*)$', '<p style="margin:0;\1');
  return new;
end $$;

drop trigger if exists email_templates_last_margin on public.email_templates;
create trigger email_templates_last_margin
  before insert or update of html_body on public.email_templates
  for each row execute function public.pm_fix_last_margin();

-- fix the stored templates now (the trigger does the work)
update public.email_templates set html_body = html_body, updated_at = now();

-- Postmark is updated afterwards by Claude (too slow for the build):
--   select public.pm_template_push(alias, true) from public.email_templates order by sort;

-- ============================================================
-- Migration 273: the last two emails tidied into Postmark templates.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: "yes please do 1 and 2".
--
-- 1. Pass on (control centre, an enquiry for a space not on Nomad Maps
--    yet): the email to the space now uses the "enquiry-to-space"
--    template, and the note to the nomad (when sent from here) the
--    nomad template, the same as every other enquiry. Only for the
--    wording as drafted; an email a founder edited goes out as written.
--    Same hand-over as migrations 259 to 261: the template is used only
--    while email_templates.live is on for it.
--
-- 2. The monthly performance email ("owner-monthly", its own layout
--    "nomadwise-layout-monthly") joins the nightly backup, so an edit in
--    Postmark is kept and can be undone like the others. Its new
--    signature and red are put in Postmark by hand once Jonathan has
--    approved the test pair (source: scripts/postmark/owner-monthly.*).
-- ============================================================

-- 1. Pass on
select public.pm_patch_fn('public.admin_enquiry_pass_on(uuid,text,boolean,text,text)',
$a$  perform public.send_enquiry_mail(
    dest, e.email,
    coalesce(nullif(btrim(p_subject), ''), draft ->> 'subject'),$a$,
$a$  -- the template only for the wording as drafted; an edited email goes as written
  begin
    if nullif(btrim(coalesce(p_subject, '')), '') is null and nullif(btrim(coalesce(p_body, '')), '') is null then
      perform public.pm_set_model('enquiry_passed', draft ->> 'alias', draft -> 'model');
    end if;
  exception when others then null; end;
  perform public.send_enquiry_mail(
    dest, e.email,
    coalesce(nullif(btrim(p_subject), ''), draft ->> 'subject'),$a$,
$m$pm_set_model('enquiry_passed', draft$m$);

select public.pm_patch_fn('public.admin_enquiry_pass_on(uuid,text,boolean,text,text)',
$a$    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io', nd ->> 'subject', nd ->> 'body',
      'enquiry_passed_nomad',$a$,
$a$    begin
      perform public.pm_set_model('enquiry_passed_nomad', nd ->> 'alias', nd -> 'model');
    exception when others then null; end;
    perform public.send_enquiry_mail(
      e.email, 'spaces@nomadwise.io', nd ->> 'subject', nd ->> 'body',
      'enquiry_passed_nomad',$a$,
$m$pm_set_model('enquiry_passed_nomad'$m$);

-- 2. The monthly email in the nightly backup
select public.pm_patch_fn('public.pm_templates_backup()',
  $a$select 'nomadwise-layout' union all$a$,
  $a$select unnest(array['nomadwise-layout', 'nomadwise-layout-monthly', 'owner-monthly']) union all$a$,
  $a$'owner-monthly'$a$);

-- Putting a kept version back: both layouts are layouts (no subject).
create or replace function public.pm_template_restore(p_version bigint) returns int
language plpgsql security definer set search_path to 'public' as $$
declare
  v  public.email_template_versions%rowtype;
  st int;
begin
  select * into v from public.email_template_versions where id = p_version;
  if not found then raise exception 'No kept version %', p_version; end if;
  if v.alias like 'nomadwise-layout%' then
    st := public.pm_put('templates/' || v.alias, jsonb_build_object(
      'Name', coalesce(v.name, 'Nomadwise email layout'), 'Alias', v.alias,
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

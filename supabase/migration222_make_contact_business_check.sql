-- ============================================================
-- Migration 222: "Make contact", and the business check before a
-- first email.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 25 Oct 2026: "with gdpr we always check if its a business
-- or not", and "Say hello" becomes "Make contact".
--
--   * outreach_business_checks: for a line in Outreach, that a founder
--     checked its email address belongs to a business (or not), who
--     and when, and the address checked (a new address is checked
--     again).
--   * admin_outreach_business_checks(): every check, by line, for the
--     Outreach cards.
--   * admin_outreach_business_check(line, ok): records one.
--   * The two first-contact templates are renamed (names only, seen in
--     Outreach > Templates; the words are unchanged).
-- Nothing is sent by itself. Pure ASCII. Safe to apply twice.
-- ============================================================

create table if not exists public.outreach_business_checks (
  contact_id uuid primary key references public.space_contacts(id) on delete cascade,
  email      text,
  ok         boolean not null,
  checked_at timestamptz not null default now(),
  checked_by uuid default auth.uid()
);
alter table public.outreach_business_checks enable row level security;
-- No policies: read and written only through the functions below.

create or replace function public.admin_outreach_business_checks()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_object_agg(b.contact_id::text, jsonb_build_object(
             'email', b.email, 'ok', b.ok, 'at', b.checked_at))
      from public.outreach_business_checks b), '{}'::jsonb);
end $$;
revoke all on function public.admin_outreach_business_checks() from public, anon;
grant execute on function public.admin_outreach_business_checks() to authenticated;

create or replace function public.admin_outreach_business_check(p_id uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  em text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select lower(btrim(coalesce(c.email, ''))) into em
    from public.space_contacts c where c.id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  insert into public.outreach_business_checks (contact_id, email, ok, checked_at, checked_by)
  values (p_id, nullif(em, ''), coalesce(p_ok, false), now(), auth.uid())
  on conflict (contact_id) do update
     set email = excluded.email, ok = excluded.ok,
         checked_at = excluded.checked_at, checked_by = excluded.checked_by;
end $$;
revoke all on function public.admin_outreach_business_check(uuid, boolean) from public, anon;
grant execute on function public.admin_outreach_business_check(uuid, boolean) to authenticated;

update public.outreach_templates
   set name = 'First contact: a new page of ours (email)'
 where key = 'invite_new_page'
   and name = 'Hello: a new page of ours (first email)';
update public.outreach_templates
   set name = 'First contact: a new page of ours (WhatsApp)'
 where key = 'invite_new_page_wa'
   and name = 'WhatsApp: hello to a new page of ours';

notify pgrst, 'reload schema';

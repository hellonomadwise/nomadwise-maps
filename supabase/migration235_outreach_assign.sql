-- ============================================================
-- Migration 235: give an Outreach box to one of us.
-- (Applied automatically by the build; nothing to paste.)
--
-- Leonie, 2 Nov 2026: each space's box can be given to Jonathan or
-- Leonie ("Assign to ..." in the box's three dots), so we can see who
-- is dealing with which, and hand one over. Both of us sign in to the
-- Control centre with the same account, so the name is picked from a
-- short list, not read from the sign-in.
--   space_contacts.assigned_to   'Jonathan', 'Leonie' or null
--   space_contacts.assigned_at   when it was given
--   admin_outreach_assign(id, who)   who null or '' takes the name off
--   admin_outreach_list   also returns assigned_to (patched in place;
--                         the rest as it stands)
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.space_contacts
  add column if not exists assigned_to text,
  add column if not exists assigned_at timestamptz;

create or replace function public.admin_outreach_assign(p_id uuid, p_who text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  who text := nullif(btrim(coalesce(p_who, '')), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if who is not null and who not in ('Jonathan', 'Leonie') then
    raise exception 'Only Jonathan or Leonie can be given a box.';
  end if;
  update public.space_contacts
     set assigned_to = who,
         assigned_at = case when who is null then null else now() end
   where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  return jsonb_build_object('ok', true, 'assigned_to', who);
end $$;
revoke all on function public.admin_outreach_assign(uuid, text) from public, anon;
grant execute on function public.admin_outreach_assign(uuid, text) to authenticated;

do $do$
declare
  src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_outreach_list';
  if src is null or position('c.assigned_to' in src) > 0 then
    return;  -- not there, or done already
  end if;
  if position('c.unsubscribed_at, c.is_test, c.topic,' in src) = 0 then
    raise exception 'admin_outreach_list is not as expected; assigned_to not added';
  end if;
  src := replace(src, 'c.unsubscribed_at, c.is_test, c.topic,',
                      'c.unsubscribed_at, c.is_test, c.topic, c.assigned_to,');
  execute src;
end
$do$;

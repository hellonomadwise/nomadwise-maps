-- ============================================================
-- Migration 82: the email log, readable from the control centre,
-- and a test button.
-- (Applied automatically by the build; nothing to paste.)
--
-- owner_emails says what we tried to send; pg_net keeps the answer
-- Postmark gave for a few hours in net._http_response. Joining the
-- two tells a founder, from the app, whether an email was skipped
-- (no token), refused by Postmark (and why) or accepted.
-- ============================================================

create or replace function public.admin_email_log(p_limit integer default 50)
returns table (
  id uuid, kind text, to_email text, subject text, ref text,
  status text, error text, created_at timestamptz,
  http_status integer, http_body text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return query
    select e.id, e.kind, e.to_email, e.subject, e.ref, e.status, e.error,
           e.created_at,
           r.status_code::integer,
           left(coalesce(r.content::text, r.error_msg, ''), 400)
      from public.owner_emails e
      left join net._http_response r
        on e.provider_req ~ '^[0-9]+$'
       and r.id = e.provider_req::bigint
     order by e.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end $$;
grant execute on function public.admin_email_log(integer) to authenticated;

-- A founder sends themselves one email to prove the pipe.
create or replace function public.admin_send_test_email(p_to text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  perform public.send_owner_email(
    p_to,
    'Test email from Nomad Maps',
    'Hi,' || E'\n\n'
    || 'This is a test sent from the control centre at '
    || to_char(now(), 'HH24:MI on DD Mon YYYY') || ' UTC. If you are reading it, '
    || 'owner emails are going out through Postmark.' || E'\n\n'
    || 'Jonathan' || E'\n' || 'Nomadwise, https://www.nomadwise.io',
    'test', null);
end $$;
grant execute on function public.admin_send_test_email(text) to authenticated;

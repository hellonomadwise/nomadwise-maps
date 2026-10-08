-- 170: clearer words for "When" on the Sequences screen.
--
-- Jonathan, 8 Oct 2026: "what does it mean on the when part 'from
-- hello@nomadwise.io, with a cc of hello@'". It meant: the email is
-- sent from hello@nomadwise.io, and a hidden copy lands in that same
-- inbox so there is a record of every email that went. Said plainly
-- now. admin_sequences() is migration 167's, with only that sentence
-- changed. Safe to apply twice.

create or replace function public.admin_sequences()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  seq public.sequences%rowtype;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into seq from public.sequences where key = 'signin_reminders';
  return jsonb_build_array(jsonb_build_object(
    'key', seq.key,
    'name', seq.name,
    'enabled', seq.enabled,
    'updated_at', seq.updated_at,
    'updated_by', seq.updated_by,
    'who', 'Spaces whose owner claimed the page themselves, with the claim approved in the '
           || 'last 90 days, who have never been into their Owner account since.',
    'when', 'Once a day, at 09:10 London time (08:10 UTC). Sent from hello@nomadwise.io; '
            || 'a hidden copy of each email also lands in that inbox, so you can see what went.',
    'leaves', 'They leave the sequence when they sign in, when it is switched off for '
              || 'their space, when they unsubscribe, or after the second email.',
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                'step', st.step,
                'enabled', st.enabled,
                'updated_at', st.updated_at,
                'updated_by', st.updated_by,
                'when', case st.step when 1 then 'Day 7 after claiming (at least 2 days after approval)'
                                     else 'Day 21 after claiming (at least 10 days after email 1)' end,
                'subject', tx.subject,
                'body', tx.body,
                'button', 'Open my Owner account',
                'sent', (select count(*) from public.sequence_sends x
                          where x.sequence_key = seq.key and x.step = st.step))
                order by st.step), '[]'::jsonb)
                from public.sequence_steps st
                cross join lateral public.signin_reminder_text(
                  st.step, '{first name}', '{space}', '{page link}') tx
               where st.sequence_key = seq.key),
    'spaces', (select coalesce(jsonb_agg(to_jsonb(s) order by
                 case s.status when 'due' then 0 when 'waiting' then 1 when 'none' then 2
                               when 'off' then 3 when 'done' then 4 when 'signed_in' then 5
                               else 6 end,
                 s.next_at nulls last, s.claimed_at desc), '[]'::jsonb)
                 from public.signin_reminder_spaces() s)));
end $$;
revoke all on function public.admin_sequences() from public, anon;
grant execute on function public.admin_sequences() to authenticated;

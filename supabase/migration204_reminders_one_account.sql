-- ============================================================
-- Migration 204: no sign-in reminders for an owner who already uses
-- the Owner account for another of their spaces.
--
-- Jonathan, 22 Oct 2026, on Sequences: Sierra Cartel claimed a second
-- location (Indiranagar) with the same email, and it was put in the
-- "you have not signed in to your Owner account for ... yet" sequence,
-- although they use the Owner account (they updated their photos the
-- same day). One email is one Owner account with all its spaces, so a
-- space now counts as signed in when its owner has signed in, or
-- opened the account, for any of their other spaces. Sequences then
-- shows it under "Left or switched off" with that date.
--
-- A copy of migration 167's signin_reminder_spaces with only that
-- change (and the owner activity read once instead of per row).
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.signin_reminder_spaces()
returns table (
  venue_id     uuid,
  name         text,
  city         text,
  country      text,
  owner_name   text,
  owner_email  text,
  claimed_at   timestamptz,
  approved_at  timestamptz,
  sent_1       timestamptz,
  sent_2       timestamptz,
  signed_in_at timestamptz,
  status       text,
  next_step    integer,
  next_at      timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  on1 boolean := coalesce((select s.enabled from public.sequence_steps s
                            where s.sequence_key = 'signin_reminders' and s.step = 1), false);
  on2 boolean := coalesce((select s.enabled from public.sequence_steps s
                            where s.sequence_key = 'signin_reminders' and s.step = 2), false);
begin
  return query
  with act as materialized (
    select * from public.outreach_owner_activity()
  ), base as (
    select v.id as vid, v.name as vname, v.city as vcity, v.country as vcountry,
           a.owner_email as em,
           -- Signed in for this space, or (migration 204) already uses
           -- the Owner account for another of their spaces: the new
           -- one is in that same account, so no reminder.
           coalesce(a.signed_in_at,
                    nullif((select max(greatest(coalesce(a2.signed_in_at, '-infinity'::timestamptz),
                                                coalesce(a2.last_open, '-infinity'::timestamptz)))
                              from act a2
                             where a2.owner_email = a.owner_email
                               and a2.venue_id <> a.venue_id
                               and not coalesce(a2.test, false)),
                           '-infinity'::timestamptz)) as signed,
           coalesce(a.opens, 0) as opens,
           k.owner_name as oname, k.created_at as claimed,
           coalesce(k.approved_at, k.paid_at, k.created_at) as approved,
           (select x.sent_at from public.sequence_sends x
             where x.sequence_key = 'signin_reminders' and x.step = 1
               and x.venue_id = v.id and x.owner_email = a.owner_email) as s1,
           (select x.sent_at from public.sequence_sends x
             where x.sequence_key = 'signin_reminders' and x.step = 2
               and x.venue_id = v.id and x.owner_email = a.owner_email) as s2,
           exists (select 1 from public.sequence_exclusions e
                    where e.sequence_key = 'signin_reminders' and e.venue_id = v.id) as excluded,
           exists (select 1 from public.space_contacts c
                    where c.venue_id = v.id and c.unsubscribed_at is not null) as unsub
      from act a
      join public.venues v on v.id = a.venue_id
      join lateral (
        select kk.* from public.listing_claims kk
         where kk.venue_id = v.id
           and lower(btrim(kk.owner_email)) = a.owner_email
           and kk.status in ('paid', 'free')
         order by kk.created_at
         limit 1) k on true
     where a.owner_email is not null
       and not coalesce(a.test, false)
       and coalesce(a.claimed_self, false)
       and (k.created_at > now() - interval '90 days'
            or exists (select 1 from public.sequence_sends x
                        where x.sequence_key = 'signin_reminders' and x.venue_id = v.id))
  ), staged as (
    select b.*,
           case when b.s1 is null and b.s2 is null and on1 then 1
                when b.s2 is null and on2 then 2 end as nstep
      from base b
  )
  select s.vid, s.vname, s.vcity, s.vcountry, s.oname, s.em, s.claimed, s.approved,
         s.s1, s.s2, s.signed,
         case when s.signed is not null or s.opens > 0 then 'signed_in'
              when s.excluded then 'off'
              when s.unsub then 'unsubscribed'
              when s.s2 is not null then 'done'
              when s.nstep is null then case when s.s1 is not null then 'done' else 'none' end
              when (case s.nstep
                      when 1 then greatest(s.claimed + interval '7 days', s.approved + interval '2 days')
                      else greatest(s.claimed + interval '21 days',
                                    coalesce(s.s1 + interval '10 days', s.claimed + interval '21 days'))
                    end) <= now() then 'due'
              else 'waiting' end,
         s.nstep,
         case s.nstep
           when 1 then greatest(s.claimed + interval '7 days', s.approved + interval '2 days')
           when 2 then greatest(s.claimed + interval '21 days',
                                coalesce(s.s1 + interval '10 days', s.claimed + interval '21 days'))
         end
    from staged s
   order by s.claimed desc;
end $$;
revoke all on function public.signin_reminder_spaces() from public, anon, authenticated;

notify pgrst, 'reload schema';

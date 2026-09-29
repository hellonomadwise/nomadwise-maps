-- ============================================================
-- Migration 102: Owners, a user group of their own.
-- (Applied automatically by the build; nothing to paste.)
--
-- Users -> Group had Customer (remote workers), Friend and Team. The
-- people who run a space now have their own group, Owner:
--   * set by hand in Users -> Group, like the others, and
--   * set automatically when an email claims a space (once the claim
--     is submitted, free or paid) or is the listed owner of a space,
--     including when that person signs in to the app for the first
--     time later on.
-- Automatic marking only ever fills an empty group (a Customer). It
-- never changes Team or Friend, and if we move an owner back to
-- Customer by hand, that sticks unless they claim another space.
--
-- Coins are for remote workers only: the app hides wallet, coin
-- chips and coin wording for Owners, and Owners are left off the
-- public leaderboard (like Team).
-- ============================================================

-- 1. Allow 'owner' as a group.
do $$
declare
  c record;
begin
  for c in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'public.profiles'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%cohort%'
  loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.profiles
  add constraint profiles_cohort_check
  check (cohort in ('team', 'friend', 'owner'));

-- 2. Is this email someone who runs a space?
create or replace function public.is_owner_email(p_email text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(trim(p_email), '') <> '' and (
    exists (select 1 from public.listing_claims c
             where lower(trim(c.owner_email)) = lower(trim(p_email))
               and c.status in ('paid', 'awaiting_approval', 'free_pending', 'free'))
    or exists (select 1 from public.venues v
                where lower(trim(v.listing_owner_email)) = lower(trim(p_email))));
$$;

-- Mark the account with this email as an Owner, if it is a Customer.
create or replace function public.mark_owner_email(p_email text)
returns void language sql security definer set search_path = public as $$
  update public.profiles p
     set cohort = 'owner'
    from auth.users u
   where u.id = p.id
     and p.cohort is null
     and coalesce(trim(p_email), '') <> ''
     and lower(trim(u.email)) = lower(trim(p_email));
$$;

-- 3. When a claim is submitted or approved.
create or replace function public.owner_group_from_claim()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('paid', 'awaiting_approval', 'free_pending', 'free')
     and (tg_op = 'INSERT' or old.status is distinct from new.status
          or old.owner_email is distinct from new.owner_email) then
    perform public.mark_owner_email(new.owner_email);
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists owner_group_from_claim on public.listing_claims;
create trigger owner_group_from_claim
  after insert or update on public.listing_claims
  for each row execute function public.owner_group_from_claim();

-- 4. When a space gets (or changes) its owner's email.
create or replace function public.owner_group_from_venue()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.listing_owner_email is not null
     and (tg_op = 'INSERT' or old.listing_owner_email is distinct from new.listing_owner_email) then
    perform public.mark_owner_email(new.listing_owner_email);
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists owner_group_from_venue on public.venues;
create trigger owner_group_from_venue
  after insert or update of listing_owner_email on public.venues
  for each row execute function public.owner_group_from_venue();

-- 5. When an owner signs in for the first time (their profile is made).
create or replace function public.owner_group_on_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  em text;
begin
  if new.cohort is null then
    select u.email into em from auth.users u where u.id = new.id;
    if public.is_owner_email(em) then
      new.cohort := 'owner';
    end if;
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists owner_group_on_profile on public.profiles;
create trigger owner_group_on_profile
  before insert on public.profiles
  for each row execute function public.owner_group_on_profile();

-- 6. Everyone who already runs a space.
update public.profiles p
   set cohort = 'owner'
  from auth.users u
 where u.id = p.id
   and p.cohort is null
   and public.is_owner_email(u.email);

-- 7. Owners are not on the public leaderboard (as with Team).
create or replace view public.leaderboard as
select
  p.id as user_id,
  coalesce(nullif(p.display_name, ''), 'Nomad') as display_name,
  p.avatar_url,
  p.created_at as member_since,
  coalesce((select sum(l.amount) from public.coin_ledger l
             where l.user_id = p.id
               and l.amount > 0
               and l.status in ('withdrawable','paid_out')), 0)::int as coins,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified')::int as verified_count,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'new_venue')::int as reviews,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'confirm')::int as confirms,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'wifi_test')::int as wifi_tests,
  (select count(*) from public.submissions s
    where s.user_id = p.id and s.status = 'verified'
      and s.kind = 'wifi_login')::int as wifi_logins
from public.profiles p
where coalesce(p.cohort, '') not in ('team', 'owner');

grant select on public.leaderboard to anon, authenticated;

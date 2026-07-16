-- ============================================================
-- Nomadwise Maps — migration 2: verification & admin
-- Paste into: Supabase -> SQL Editor -> New query -> Run
-- (Safe to run more than once.)
-- ============================================================

-- ---------- 1. Admin flag ----------
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Jonathan is the admin.
update public.profiles set is_admin = true
where id in (select id from auth.users where email = 'hellonomadwise@gmail.com');

-- Helper used by the security policies below.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as
$$ select coalesce((select is_admin from public.profiles where id = auth.uid()), false) $$;

-- ---------- 2. Auto-verify confirmations (photo + GPS <= 150 m) ----------
create or replace function public.auto_verify_confirm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'confirm'
     and new.photo_path is not null
     and new.gps_distance_m is not null
     and new.gps_distance_m <= 150 then
    update public.submissions
       set status = 'verified', verified_at = now()
     where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_auto_verify on public.submissions;
create trigger trg_auto_verify
  after insert on public.submissions
  for each row execute function public.auto_verify_confirm();

-- ---------- 3. Verified confirmations update the venue's data ----------
create or replace function public.apply_confirm_payload()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'confirm' and new.venue_id is not null then
    update public.venues v set
      laptops_allowed     = coalesce((new.payload->>'laptops_allowed')::boolean, v.laptops_allowed),
      wifi_speed_mbps     = coalesce((new.payload->>'wifi_speed_mbps')::numeric, v.wifi_speed_mbps),
      power_outlets       = coalesce((new.payload->>'power_outlets')::boolean, v.power_outlets),
      aircon              = coalesce((new.payload->>'aircon')::boolean, v.aircon),
      comfortable_seating = coalesce((new.payload->>'comfortable_seating')::boolean, v.comfortable_seating),
      cozy                = coalesce((new.payload->>'cozy')::boolean, v.cozy),
      quiet_space         = coalesce((new.payload->>'quiet_space')::boolean, v.quiet_space),
      neighbourhood       = coalesce(nullif(new.payload->>'neighbourhood',''), v.neighbourhood),
      updated_at          = now()
    where v.id = new.venue_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_apply_confirm on public.submissions;
create trigger trg_apply_confirm
  after update on public.submissions
  for each row execute function public.apply_confirm_payload();

-- ---------- 4. Admin access rules ----------
drop policy if exists "admin reads all submissions" on public.submissions;
create policy "admin reads all submissions" on public.submissions
  for select using (public.is_admin());

drop policy if exists "admin updates submissions" on public.submissions;
create policy "admin updates submissions" on public.submissions
  for update using (public.is_admin());

drop policy if exists "admin updates venues" on public.venues;
create policy "admin updates venues" on public.venues
  for update using (public.is_admin());

drop policy if exists "admin reads pending venues" on public.venues;
create policy "admin reads pending venues" on public.venues
  for select using (public.is_admin());

drop policy if exists "admin reads all ledgers" on public.coin_ledger;
create policy "admin reads all ledgers" on public.coin_ledger
  for select using (public.is_admin());

drop policy if exists "admin reads all profiles" on public.profiles;
create policy "admin reads all profiles" on public.profiles
  for select using (public.is_admin());

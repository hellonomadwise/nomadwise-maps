-- ============================================================
-- Nomadwise Maps — migration 16: first-discoverer bonus
-- Paste into: Supabase -> SQL Editor -> New query -> Run
--
-- The signed-in user whose search first revealed a space earns
-- +10 coins when that space later gets screened and approved.
-- ============================================================

-- 1. Remember who found each place (and whether they were paid).
alter table public.discovered_places
  add column if not exists discovered_by uuid references auth.users(id),
  add column if not exists bonus_paid boolean not null default false;

-- 2. Pay the finder when the space's review is verified.
create or replace function public.pay_discovery_bonus()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  dp record;
begin
  if new.status = 'verified' and old.status <> 'verified'
     and new.kind = 'new_venue' then
    select d.google_place_id, d.discovered_by into dp
      from public.venues v
      join public.discovered_places d
        on d.google_place_id = v.google_place_id
     where v.id = new.venue_id
       and d.discovered_by is not null
       and not d.bonus_paid
     limit 1;
    if found then
      insert into public.coin_ledger
        (user_id, submission_id, amount, status, note)
      values (dp.discovered_by, new.id, 10, 'withdrawable',
              'Discovery bonus: you put this space on the map first');
      update public.discovered_places
         set bonus_paid = true
       where google_place_id = dp.google_place_id;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_discovery_bonus on public.submissions;
create trigger trg_discovery_bonus
  after update on public.submissions
  for each row execute function public.pay_discovery_bonus();

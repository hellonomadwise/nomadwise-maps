-- Migration 361: a city can be swept for coworking spaces only
-- (Jonathan, 25 Nov 2026: "go sweep build").
--
-- Before: one kind of city sweep. It searches every cafe in a city on
-- a fine grid and then coworking on a coarse one: about 115 Google
-- searches a city, most of them for cafes, one city a night.
--
-- Now sweep_queue.kind says which sweep a city gets: 'full' (as
-- before, and what the app's "Sweep a city" still asks for) or
-- 'coworking' (the coarse coworking grid only, about 22 searches a
-- city). The nightly job does up to five coworking-only cities a
-- night. city_sweeps.kind records which kind was done. A city that
-- has had a full sweep is not swept again for coworking.
--
-- Applied to the live database on 25 Nov 2026.

alter table public.sweep_queue
  add column if not exists kind text not null default 'full';
alter table public.city_sweeps
  add column if not exists kind text not null default 'full';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'sweep_queue_kind_check') then
    alter table public.sweep_queue add constraint sweep_queue_kind_check
      check (kind in ('full', 'coworking'));
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'city_sweeps_kind_check') then
    alter table public.city_sweeps add constraint city_sweeps_kind_check
      check (kind in ('full', 'coworking'));
  end if;
end $$;

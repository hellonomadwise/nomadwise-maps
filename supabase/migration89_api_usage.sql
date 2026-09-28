-- ============================================================
-- Migration 89: count Google calls, by job and by bill line.
-- (Applied automatically by the build; nothing to paste.)
--
-- The Google bill says what kind of call cost money (Place Details
-- Pro, Photos...) but not which of our jobs made it. Every job now
-- tallies its own Google calls under the bill's names and adds them
-- here per day; the app does the same for the calls visitors'
-- browsers make (source 'app'). The control centre's "Google calls"
-- screen reads this, so a bill can be matched line by line.
--
--   api_usage  day, source (the job, or 'app'), sku (bill line),
--              calls (answered, billed), errors (refused, not billed)
-- ============================================================

create table if not exists public.api_usage (
  day date not null,
  source text not null,
  sku text not null,
  calls integer not null default 0,
  errors integer not null default 0,
  primary key (day, source, sku)
);

alter table public.api_usage enable row level security;

drop policy if exists api_usage_admin_read on public.api_usage;
create policy api_usage_admin_read on public.api_usage
  for select using (public.is_admin());

-- Adds one run's tally. The jobs call it with the service key; the
-- app calls it as a visitor, so for visitors the source is forced to
-- 'app' and the numbers are capped (a tally covers about a minute).
create or replace function public.record_api_usage(
  p_day date, p_source text, p_counts jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  k text;
  v jsonb;
  src text := left(coalesce(p_source, 'unknown'), 40);
  cap integer := 1000000;
begin
  if jsonb_typeof(coalesce(p_counts, 'null'::jsonb)) <> 'object' then
    return;
  end if;
  if coalesce(auth.role(), '') <> 'service_role' then
    src := 'app';
    cap := 500;
  end if;
  for k, v in select key, value from jsonb_each(p_counts) limit 30 loop
    if k !~ '^(Place Details|Text Search|Nearby Search|Autocomplete)' then
      continue;
    end if;
    insert into public.api_usage as u (day, source, sku, calls, errors)
    values (coalesce(p_day, current_date), src, left(k, 60),
            least(greatest(coalesce((v->>'calls')::int, 0), 0), cap),
            least(greatest(coalesce((v->>'errors')::int, 0), 0), cap))
    on conflict (day, source, sku) do update
       set calls = u.calls + excluded.calls,
           errors = u.errors + excluded.errors;
  end loop;
exception when others then
  return;
end $$;

revoke all on function public.record_api_usage(date, text, jsonb) from public;
grant execute on function public.record_api_usage(date, text, jsonb)
  to anon, authenticated, service_role;

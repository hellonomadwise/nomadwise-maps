-- ============================================================
-- Migration 94: "Something need updating? Let us know", in Nomad Maps.
-- (Applied automatically by the build; nothing to paste.)
--
-- The link on every nomadwise.io listing page went to a retired form.
-- It now opens nomadmaps.io/?update=<slug>: owners are pointed to
-- claiming the page (they then change it themselves), and anyone else
-- tells us what has changed. Each report lands here, pings the phone,
-- and shows in the control centre (Owner changes, Suggested updates)
-- to be fixed or dismissed.
--
--   listing_updates  venue, what changed (kinds), details, when they
--                    were last there, optional name and email for a
--                    follow-up question, status open / done / dismissed
-- ============================================================

create table if not exists public.listing_updates (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid references public.venues(id) on delete set null,
  slug        text,
  space_name  text,
  kinds       text[] not null default '{}',
  details     text check (char_length(details) <= 3000),
  last_visit  text,
  name        text check (char_length(name) <= 120),
  email       text check (char_length(email) <= 200),
  status      text not null default 'open'
              check (status in ('open', 'done', 'dismissed')),
  note        text,
  created_at  timestamptz not null default now(),
  handled_at  timestamptz
);
create index if not exists idx_listing_updates_open
  on public.listing_updates(status, created_at desc);

alter table public.listing_updates enable row level security;
drop policy if exists "listing_updates admin" on public.listing_updates;
create policy "listing_updates admin" on public.listing_updates
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Anyone may send one; nobody but the founders reads them.
create or replace function public.submit_listing_update(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid := nullif(trim(coalesce(p->>'venue_id', '')), '')::uuid;
  v_name  text;
  v_slug  text;
  kinds   text[];
  det     text := nullif(left(trim(coalesce(p->>'details', '')), 3000), '');
  em      text := nullif(lower(left(trim(coalesce(p->>'email', '')), 200)), '');
  new_id  uuid;
  labels  text;
begin
  if v_id is null then
    raise exception 'Which listing is this about?';
  end if;
  select name, webflow_slug into v_name, v_slug from public.venues where id = v_id;
  if v_name is null then
    raise exception 'That listing could not be found.';
  end if;

  select coalesce(array_agg(k), '{}') into kinds
    from (select distinct left(x, 40) as k
            from jsonb_array_elements_text(coalesce(p->'kinds', '[]'::jsonb)) x
           limit 12) s;
  if coalesce(array_length(kinds, 1), 0) = 0 and det is null then
    raise exception 'Tell us what has changed.';
  end if;
  if em is not null and position('@' in em) < 2 then
    em := null;
  end if;

  if (select count(*) from public.listing_updates
       where venue_id = v_id and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Thanks, we already have a few reports about this listing; we are on it.';
  end if;
  if (select count(*) from public.listing_updates
       where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Too many reports right now; please try again later.';
  end if;

  insert into public.listing_updates (venue_id, slug, space_name, kinds, details,
                                      last_visit, name, email)
  values (v_id, v_slug, v_name, kinds, det,
          nullif(left(trim(coalesce(p->>'last_visit', '')), 40), ''),
          nullif(left(trim(coalesce(p->>'name', '')), 120), ''),
          em)
  returning id into new_id;

  labels := array_to_string(kinds, ', ');
  perform public.notify_phone(
    'Update suggested: ' || v_name,
    coalesce(nullif(labels, ''), 'Something changed')
      || coalesce(': ' || left(det, 140), '')
      || '. See Owner changes, Suggested updates.',
    'pencil');
  return new_id;
end $$;
revoke all on function public.submit_listing_update(jsonb) from public;
grant execute on function public.submit_listing_update(jsonb) to anon, authenticated;

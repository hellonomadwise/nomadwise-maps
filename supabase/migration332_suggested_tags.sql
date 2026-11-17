-- Migration 332: a visitor's suggested tags can be put on the page in
-- one tap, and an owner pressing "Add a tag" on a page that is already
-- theirs is no longer sent to the claim page.
--
-- Jonathan, 17 Nov 2026, on the card "Neighbors and Nomads Coworking,
-- Tags to add" in Quality > Suggestions: "What is this? What is the
-- action, how can this become actioned". The only buttons were Open the
-- page, Mark done and Dismiss: the tags had to be put on by hand
-- somewhere else. The card was the space's own owner, three minutes
-- after his first sign-in: he pressed "I run Neighbors and Nomads"
-- twice, was sent to the claim page each time ("Someone has already
-- claimed this listing"), and went in as a visitor instead.
--
-- 1. venues.tags_pending: the tags one of us has just added from a
--    suggestion and that the website run has not written yet. The run
--    writes them to the page (owner content or not) and empties it; the
--    nightly read leaves them alone until then.
-- 2. admin_listing_update_tags(id, apply): what a "Tags to add"
--    suggestion would change (added, already there, cannot be shown),
--    and with apply, does it and marks the suggestion done.
-- 3. listing_has_owner(slug): whether a page has an owner. The page
--    itself already says so ("Managed by its owner"), so nothing new is
--    given away; "Add a tag" and "Something need updating?" use it to
--    send an owner to their Owner account.

alter table public.venues add column if not exists tags_pending jsonb;
comment on column public.venues.tags_pending is
  'Tags added from a visitor''s suggestion, waiting for the website run to write them: {"cozy": true}. Emptied once written. Migration 332.';

create or replace function public.listing_has_owner(p_slug text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.venues v
     where v.webflow_slug = btrim(coalesce(p_slug, ''))
       and coalesce(btrim(v.listing_owner_email), '') <> '');
$$;
revoke all on function public.listing_has_owner(text) from public;
grant execute on function public.listing_has_owner(text) to anon, authenticated, service_role;

create or replace function public.admin_listing_update_tags(p_id uuid, p_apply boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  u     public.listing_updates%rowtype;
  v     jsonb;
  -- the words of the "Add a tag" form (old and new), and where each
  -- lives on a space
  cols  constant jsonb := '{
    "enough plug sockets": "power_outlets",
    "comfortable seating": "comfortable_seating",
    "office chairs": "office_chairs",
    "monitors available": "monitor",
    "quiet room or phone booth": "call_room",
    "good for video calls": "good_for_calls",
    "aircon": "aircon",
    "low background music": "low_background_music",
    "no traffic noise": "no_traffic_noise",
    "cozy": "cozy",
    "24-hour access": "access_24h",
    "vegan friendly": "vegan_friendly",
    "instagrammable": "instagramable",
    "quiet space": "quiet_space",
    "swimming pool": "swimming_pool"
  }';
  line  text;
  t     text;
  col   text;
  added text[] := '{}';
  had   text[] := '{}';
  cant  text[] := '{}';
  setc  text[] := '{}';
  sets  text;
  pend  jsonb;
  v_note text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into u from public.listing_updates where id = p_id;
  if not found then
    raise exception 'This suggestion is no longer there.';
  end if;
  if u.venue_id is null then
    raise exception 'This suggestion is not tied to a space, so its tags cannot be added from here.';
  end if;
  select to_jsonb(x) into v from public.venues x where x.id = u.venue_id;
  if v is null then
    raise exception 'The space this suggestion is about is no longer there.';
  end if;

  select substring(l from '^\s*Tags:\s*(.*)$') into line
    from regexp_split_to_table(coalesce(u.details, ''), E'\n') l
   where l ~ '^\s*Tags:'
   limit 1;

  for t in
    select btrim(x) from regexp_split_to_table(coalesce(line, ''), ',') x
     where btrim(x) <> ''
  loop
    col := cols ->> lower(t);
    if lower(t) = 'fast wifi' then
      -- the page shows the speed itself, from a test
      if coalesce(nullif(v ->> 'wifi_speed_mbps', '')::numeric, 0) > 0 then
        had := had || t;
      else
        cant := cant || (t || ' (the page shows a tested speed; none yet)');
      end if;
    elsif col is null then
      cant := cant || t;
    elsif (v ->> col)::boolean is true then
      had := had || t;
    elsif not (col = any (setc)) then
      added := added || t;
      setc := setc || col;
    end if;
  end loop;

  if p_apply then
    if coalesce(array_length(setc, 1), 0) > 0 then
      select string_agg(format('%I = true', c), ', ') into sets from unnest(setc) c;
      pend := coalesce(nullif(v -> 'tags_pending', 'null'::jsonb), '{}'::jsonb)
              || (select jsonb_object_agg(c, true) from unnest(setc) c);
      execute format(
        'update public.venues set %s, tags_pending = $1, '
        'listing_sync_requested_at = now(), listing_synced_at = null where id = $2', sets)
        using pend, u.venue_id;
    end if;
    v_note := concat_ws(' ',
      case when coalesce(array_length(added, 1), 0) > 0
           then 'Added: ' || array_to_string(added, ', ') || '.' end,
      case when coalesce(array_length(had, 1), 0) > 0
           then 'Already on the page: ' || array_to_string(had, ', ') || '.' end,
      case when coalesce(array_length(cant, 1), 0) > 0
           then 'Not a tag the page can show: ' || array_to_string(cant, ', ') || '.' end);
    update public.listing_updates
       set status = 'done', handled_at = now(),
           note = nullif(btrim(coalesce(v_note, '')), '')
     where id = p_id;
  end if;

  return jsonb_build_object(
    'space', coalesce(v ->> 'name', u.space_name),
    'added', to_jsonb(added), 'had', to_jsonb(had), 'cannot', to_jsonb(cant),
    'applied', p_apply,
    'on_site', nullif(v ->> 'webflow_cms_id', '') is not null);
end $function$;
revoke all on function public.admin_listing_update_tags(uuid, boolean) from public, anon;
grant execute on function public.admin_listing_update_tags(uuid, boolean) to authenticated, service_role;

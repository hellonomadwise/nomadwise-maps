-- Migration 333: the phone notification "Owner changes to review" says
-- what changed.
--
-- Jonathan, 17 Nov 2026, with the notification for Neighbors and
-- Nomads Coworking ("the owner submitted changes to their page. Read
-- them in Owner changes and put them on, or send them back."): "when
-- there is one saying owner has made changes, I'd like to know briefly
-- what changes".
--
-- An owner's submission is the whole listing, changed or not. So what
-- changed is worked out against what the space holds now, part by part,
-- and said in a few words:
--   "Neighbors and Nomads Coworking: new description, 3 tags added,
--    WhatsApp, Instagram. Review in Owner changes."
-- When nothing can be told apart (a submission with no visible change),
-- the old sentence is kept.

create or replace function public.owner_draft_changes(p_venue uuid, p_draft jsonb)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v      jsonb;
  oc     jsonb;
  d      jsonb := coalesce(p_draft, '{}'::jsonb);
  parts  text[] := '{}';
  a      text;
  b      text;
  k      text;
  added  text[] := '{}';
  gone   text[] := '{}';
  names  constant jsonb := '{
    "laptops_allowed": "Laptops welcome", "power_outlets": "Plug sockets",
    "good_for_calls": "Good for calls", "quiet_space": "Quiet area",
    "comfortable_seating": "Comfortable seating", "aircon": "Aircon",
    "access_24h": "24 hour access", "call_room": "Call room",
    "monitor": "Monitors", "office_chairs": "Office chairs", "cozy": "Cozy",
    "swimming_pool": "Swimming pool", "no_traffic_noise": "No traffic noise",
    "low_background_music": "Low background music",
    "instagramable": "Instagramable", "vegan_friendly": "Vegan friendly",
    "pass_required": "Pass required"}';
  n      integer;
begin
  select to_jsonb(x) into v from public.venues x where x.id = p_venue;
  if v is null then return null; end if;
  oc := coalesce(nullif(v -> 'owner_content', 'null'::jsonb), '{}'::jsonb);

  -- description (the box starts filled with the page's own text)
  a := btrim(coalesce(d ->> 'description', ''));
  b := btrim(coalesce(nullif(oc ->> 'description', ''), v ->> 'page_description', ''));
  if a <> b then
    parts := parts || case when a = '' then 'description removed'
                           when b = '' then 'new description'
                           else 'description changed' end;
  end if;

  -- photos
  if jsonb_typeof(d -> 'photos') = 'array' and jsonb_array_length(d -> 'photos') > 0
     and (d -> 'photos') is distinct from (oc -> 'photos') then
    n := jsonb_array_length(d -> 'photos');
    parts := parts || (n || case when n = 1 then ' photo' else ' photos' end);
  end if;

  -- tags: only what the owner said yes or no to
  for k in select jsonb_object_keys(coalesce(d -> 'facts', '{}'::jsonb)) loop
    if not (names ? k) then continue; end if;
    if (d -> 'facts' ->> k)::boolean is true and (v ->> k)::boolean is not true then
      added := added || (names ->> k);
    elsif (d -> 'facts' ->> k)::boolean is false and (v ->> k)::boolean is true then
      gone := gone || (names ->> k);
    end if;
  end loop;
  if coalesce(array_length(added, 1), 0) between 1 and 3 then
    parts := parts || ('tags added (' || array_to_string(added, ', ') || ')');
  elsif coalesce(array_length(added, 1), 0) > 3 then
    parts := parts || (array_length(added, 1) || ' tags added');
  end if;
  if coalesce(array_length(gone, 1), 0) between 1 and 3 then
    parts := parts || ('tags removed (' || array_to_string(gone, ', ') || ')');
  elsif coalesce(array_length(gone, 1), 0) > 3 then
    parts := parts || (array_length(gone, 1) || ' tags removed');
  end if;

  -- opening hours, day by day
  if exists (
    select 1 from unnest(array['mon','tue','wed','thu','fri','sat','sun']) dd
     -- (a long dash for a short one, or another kind of space, is
     -- not a change: Google writes "7:00 AM – 10:00 PM")
     where regexp_replace(translate(lower(coalesce(d -> 'hours' ->> dd, '')),
             chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '),
             '[\s-]+', '', 'g')
           is distinct from
           regexp_replace(translate(lower(coalesce(v -> 'opening_hours' ->> dd, '')),
             chr(8211) || chr(8212) || chr(160) || chr(8239) || chr(8201), '--   '),
             '[\s-]+', '', 'g')
       and jsonb_typeof(d -> 'hours') = 'object' and (d -> 'hours') <> '{}'::jsonb) then
    parts := parts || 'opening hours'::text;
  end if;

  -- the old day, week and month prices and the coffee
  if exists (
    select 1 from unnest(array['day','week','month','coffee']) pp
     where btrim(coalesce(d -> 'prices' ->> pp, ''))
           is distinct from btrim(coalesce(oc -> 'prices' ->> pp, ''))) then
    parts := parts || 'prices'::text;
  end if;

  -- links
  a := lower(regexp_replace(btrim(coalesce(d ->> 'website', '')), '/+$', ''));
  b := lower(regexp_replace(btrim(coalesce(v ->> 'website', '')), '/+$', ''));
  if a <> '' and a <> b then parts := parts || 'website'::text; end if;

  a := lower(regexp_replace(regexp_replace(btrim(coalesce(d ->> 'instagram', '')),
         '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@|[/?].*$', '', 'g'));
  b := lower(regexp_replace(regexp_replace(btrim(coalesce(v ->> 'instagram', '')),
         '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@|[/?].*$', '', 'g'));
  if a <> '' and a <> b then parts := parts || 'Instagram'::text; end if;

  a := regexp_replace(coalesce(d ->> 'whatsapp', ''), '[^0-9]', '', 'g');
  b := regexp_replace(coalesce(oc ->> 'whatsapp', ''), '[^0-9]', '', 'g');
  if a <> b then
    parts := parts || case when a = '' then 'WhatsApp removed' else 'WhatsApp' end;
  end if;

  -- where requests go
  a := lower(btrim(coalesce(d ->> 'enquiry_email', '')));
  b := lower(btrim(coalesce(v ->> 'listing_enquiry_email', '')));
  if a <> '' and a <> b then parts := parts || 'where requests go'::text; end if;

  -- the Premium message
  if btrim(coalesce(d -> 'mention' ->> 'title', '')) <> ''
     and (btrim(coalesce(d -> 'mention' ->> 'title', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'title', ''))
          or btrim(coalesce(d -> 'mention' ->> 'body', ''))
            is distinct from btrim(coalesce(oc -> 'mention' ->> 'body', ''))) then
    parts := parts || 'Premium message'::text;
  end if;

  -- the price list (Passes and prices): sent just before the listing,
  -- and waiting for one of us
  select count(*) into n from public.product_changes pc
   where pc.venue_id = p_venue and pc.source = 'owner' and pc.status = 'proposed';
  if n > 0 then
    parts := parts || ('price list (' || n || case when n = 1 then ' change)' else ' changes)' end);
  end if;

  if coalesce(array_length(parts, 1), 0) = 0 then return null; end if;
  return array_to_string(parts, ', ');
exception when others then
  -- a notification must never stop an owner's save
  return null;
end $function$;
revoke all on function public.owner_draft_changes(uuid, jsonb) from public, anon, authenticated;

-- the notification says it
select public.pm_patch_fn('public.owner_save_draft(uuid,jsonb,boolean)',
  $a$      coalesce(v_name, 'A space') || ': the owner submitted changes to their '
        'page. Read them in Owner changes and put them on, or send them back.',$a$,
  $a$      coalesce(v_name, 'A space') || ': '
        || coalesce(public.owner_draft_changes(p_venue, clean) || '. Review in Owner changes.',
                    'the owner submitted changes to their page. Read them in '
                    'Owner changes and put them on, or send them back.'),$a$,
  $a$owner_draft_changes$a$);

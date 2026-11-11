-- ============================================================
-- Migration 318: a ping when an owner takes a website badge, and
-- "Took a badge" on Home
-- ============================================================
-- Jonathan, 11 Nov 2026: "can we make it so that I receive a
-- notification whenever anyone downloads the website badges. and
-- that this is recorded within the dashboard summary".
--
-- An owner takes a badge in two ways, both in the Owner account under
-- the website badge: "Copy code" (the badge for their own website)
-- and "Download media pack (ZIP)". The app already notes both as
-- steps in Owner activity (owner_activity, kinds badge_copied and
-- badge_pack, migration 283). Nobody had pressed either before today.
--
-- * A phone ping for each, with the space's name and which badge.
--   One ping per owner per kind an hour, so an owner copying three
--   styles in a row is one ping, not three. Our own team is left out
--   (a founder's preview sends nothing anyway).
-- * Home, "Owners each day": a fourth row, "Took a badge", with the
--   spaces listed when a day is tapped.
-- ============================================================

create or replace function public.owner_badge_ping()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  vname text;
  team  boolean;
  what  text;
begin
  if new.kind not in ('badge_copied', 'badge_pack') then
    return new;
  end if;
  select coalesce(s.team, false) into team from public.owner_sessions s where s.id = new.session_id;
  if coalesce(team, false)
     or lower(coalesce(new.owner_email, '')) like '%nomadwise%'
     or lower(coalesce(new.owner_email, '')) in (select lower(email) from public.owner_flow_team_emails) then
    return new;
  end if;
  -- the first of its kind from this owner in the hour
  if exists (select 1 from public.owner_activity a
              where a.owner_email = new.owner_email and a.kind = new.kind
                and a.id <> new.id
                and a.at > new.at - interval '60 minutes'
                and (a.at, a.id) < (new.at, new.id)) then
    return new;
  end if;
  select v.name into vname from public.venues v where v.id = new.venue_id;
  what := nullif(btrim(coalesce(new.detail ->> 'badge', '')), '');
  perform public.notify_phone(
    case new.kind when 'badge_copied' then 'Badge code copied: ' else 'Badge pack downloaded: ' end
      || coalesce(vname, 'an owner'),
    case new.kind
      when 'badge_copied' then
        'They copied the code to put the badge on their website'
        || coalesce(' (' || case when what like 'verified-%' then 'Verified, ' else '' end
                    || replace(regexp_replace(what, '^(find|verified)-', ''), '-', ', ') || ')', '')
        || '.'
      else
        'They downloaded the media pack'
        || case when new.detail ->> 'plan' = 'verified' then ' (Premium)'
                when new.detail ->> 'plan' = 'find' then ' (Free)' else '' end || '.'
    end,
    'label');
  return new;
exception when others then
  return new;     -- a ping never gets in the way of the Owner account
end $function$;

create or replace trigger owner_badge_ping
  after insert on public.owner_activity
  for each row
  when (new.kind in ('badge_copied', 'badge_pack'))
  execute function public.owner_badge_ping();

-- Home, "Owners each day": who took a badge.
select public.pm_patch_fn('public.admin_home_owner_days(integer)',
$a$names as ($a$,
$a$badged as (
      select distinct (a.at at time zone 'Europe/London')::date as day, a.venue_id
        from public.owner_activity a
        left join public.owner_sessions s on s.id = a.session_id
       where a.kind in ('badge_copied', 'badge_pack')
         and a.venue_id is not null
         and a.at >= d0 - 1
         and not coalesce(s.team, false)
         and lower(coalesce(a.owner_email, '')) not like '%nomadwise%'
         and lower(coalesce(a.owner_email, '')) not in (select email from team)
    ),
    names as ($a$,
$m$badged as ($m$);

select public.pm_patch_fn('public.admin_home_owner_days(integer)',
$a$'updated', (select count(*) from updated u where u.day = g.day),$a$,
$a$'updated', (select count(*) from updated u where u.day = g.day),
             'badge', (select count(*) from badged b where b.day = g.day),
             'badge_names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
                               from badged b join names n on n.id = b.venue_id where b.day = g.day),$a$,
$m$'badge_names'$m$);

-- Migration 252: the Performance tab in the Owner account.
--
-- 1. page_google_days: how often Google showed each listing page
--    (Search Console impressions and clicks per page per day). Filled
--    by the "listing_google" Apps Script in the Nomadwise GSC feed
--    sheet, which calls gsc_listing_import every morning with the last
--    10 days (and once with the last 16 months). Search Console runs
--    about 3 days behind.
-- 2. page_google_queries: the searches that showed each listing page,
--    last 90 days, top 10 a page; replaced on every import.
-- 3. gsc_listing_imports: one row per import, to check it still runs.
-- 4. owner_performance(venue, days): everything the Performance tab
--    shows, for 30, 91 or 365 days. Numbers that are 0 are sent as 0;
--    the app leaves them out (Jonathan: only activity worth showing).
-- 5. page_parts(venue): the "Get more from your page" checklist, the
--    same for the Owner account and the monthly email.

create table if not exists public.page_google_days (
  venue_id    uuid not null references public.venues(id) on delete cascade,
  day         date not null,
  impressions integer not null default 0,
  clicks      integer not null default 0,
  primary key (venue_id, day)
);
alter table public.page_google_days enable row level security;

create table if not exists public.page_google_queries (
  venue_id    uuid not null references public.venues(id) on delete cascade,
  query       text not null,
  impressions integer not null default 0,
  clicks      integer not null default 0,
  primary key (venue_id, query)
);
alter table public.page_google_queries enable row level security;

create table if not exists public.gsc_listing_imports (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  day_rows    integer,
  first_day   date,
  last_day    date,
  pages       integer,
  unmatched   integer,
  query_rows  integer
);
alter table public.gsc_listing_imports enable row level security;

-- The listing slug in a nomadwise.io/coworking/ address, or null.
create or replace function public.listing_slug(p_url text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select case when coalesce(p_url, '') ~* '^https?://(www\.)?nomadwise\.io/coworking/[^/?#]'
    then lower(regexp_replace(
           regexp_replace(p_url, '^https?://(www\.)?nomadwise\.io/coworking/', '', 'i'),
           '[/?#].*$', '')) end;
$function$;

-- Every listing slug (lower case) and its space; an exact match wins
-- when two spaces differ only in capitals.
create or replace function public.listing_slugs()
returns table (slug text, id uuid)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select distinct on (lower(webflow_slug)) lower(webflow_slug), id
    from public.venues
   where coalesce(webflow_slug, '') <> ''
   order by lower(webflow_slug), (webflow_slug = lower(webflow_slug)) desc, id;
$function$;

-- Called by the Apps Script with the sheet's own secret key (service
-- role only). p_days: [{page, day, impressions, clicks}], day rows are
-- replaced, not added. p_queries (optional): [{page, query,
-- impressions, clicks}]; when given, the searches table is replaced.
create or replace function public.gsc_listing_import(p_days jsonb, p_queries jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n_days  int := 0;
  n_pages int := 0;
  n_miss  int := 0;
  n_q     int := null;
  d1 date;
  d2 date;
begin
  if jsonb_typeof(coalesce(p_days, '[]'::jsonb)) <> 'array' then
    raise exception 'p_days must be a list';
  end if;

  drop table if exists _gsc_in;
  create temp table _gsc_in on commit drop as
  with r as (
    select r ->> 'page' as page,
           (r ->> 'day')::date as day,
           greatest(coalesce((r ->> 'impressions')::numeric, 0), 0)::int as impressions,
           greatest(coalesce((r ->> 'clicks')::numeric, 0), 0)::int as clicks
      from jsonb_array_elements(coalesce(p_days, '[]'::jsonb)) r
     where (r ->> 'day') ~ '^\d{4}-\d{2}-\d{2}$'
  )
  select s.id as venue_id, r.page, r.day, r.impressions, r.clicks
    from r
    left join public.listing_slugs() s on s.slug = public.listing_slug(r.page);

  select count(distinct page) filter (where venue_id is null),
         count(distinct venue_id), min(day), max(day)
    into n_miss, n_pages, d1, d2
    from _gsc_in;

  insert into public.page_google_days as g (venue_id, day, impressions, clicks)
  select venue_id, day, sum(impressions), sum(clicks)
    from _gsc_in
   where venue_id is not null
   group by venue_id, day
  on conflict (venue_id, day)
  do update set impressions = excluded.impressions, clicks = excluded.clicks;
  get diagnostics n_days = row_count;

  if p_queries is not null and jsonb_typeof(p_queries) = 'array' then
    delete from public.page_google_queries where true;
    insert into public.page_google_queries (venue_id, query, impressions, clicks)
    select venue_id, query, impressions, clicks
      from (
        select venue_id, query, sum(impressions)::int as impressions,
               sum(clicks)::int as clicks,
               row_number() over (partition by venue_id
                                  order by sum(impressions) desc, query) as rk
          from (
            select s.id as venue_id,
                   left(btrim(r ->> 'query'), 200) as query,
                   greatest(coalesce((r ->> 'impressions')::numeric, 0), 0) as impressions,
                   greatest(coalesce((r ->> 'clicks')::numeric, 0), 0) as clicks
              from jsonb_array_elements(p_queries) r
              join public.listing_slugs() s
                on s.slug = public.listing_slug(r ->> 'page')) x
         where venue_id is not null and coalesce(query, '') <> ''
         group by venue_id, query) y
     where rk <= 10;
    get diagnostics n_q = row_count;
  end if;

  insert into public.gsc_listing_imports (day_rows, first_day, last_day, pages, unmatched, query_rows)
  values (n_days, d1, d2, n_pages, n_miss, n_q);

  return jsonb_build_object('day_rows', n_days, 'pages', n_pages,
    'unmatched_pages', n_miss, 'first_day', d1, 'last_day', d2,
    'query_rows', n_q);
end $function$;

revoke all on function public.gsc_listing_import(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.gsc_listing_import(jsonb, jsonb) to service_role;
revoke all on function public.listing_slugs() from public, anon, authenticated;

-- The parts of a page that make people choose it, in the order the
-- checklist shows them, and which one to add next (prices first: with
-- prices people pick one and send a request in one go).
create or replace function public.page_parts(p_venue uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v public.venues%rowtype;
  x jsonb;
  parts jsonb;
  nxt text;
  hours_ok boolean;
begin
  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;
  x := public.owner_page_extras(v);
  hours_ok :=
    exists (select 1 from jsonb_each_text(
              case when jsonb_typeof(v.opening_hours) = 'object'
                   then v.opening_hours else '{}'::jsonb end) h
             where btrim(h.value) <> '')
    or exists (select 1 from jsonb_each_text(
              case when jsonb_typeof(x -> 'google_hours') = 'object'
                   then x -> 'google_hours' else '{}'::jsonb end) h
             where btrim(h.value) <> '');
  parts := jsonb_build_array(
    jsonb_build_object('key', 'photos', 'done',
      jsonb_array_length(coalesce(x -> 'page_photos', '[]'::jsonb)) > 0),
    jsonb_build_object('key', 'hours', 'done', hours_ok),
    jsonb_build_object('key', 'description', 'done',
      coalesce(btrim(x ->> 'page_description'), '') <> ''),
    jsonb_build_object('key', 'prices', 'done',
      jsonb_array_length(coalesce(x -> 'page_products', '[]'::jsonb)) > 0),
    jsonb_build_object('key', 'wifi', 'done', v.wifi_speed_mbps is not null));
  select k into nxt
    from unnest(array['prices', 'photos', 'description', 'wifi', 'hours']) with ordinality as o(k, i)
   where exists (select 1 from jsonb_array_elements(parts) p
                  where p ->> 'key' = o.k and not (p ->> 'done')::boolean)
   order by i limit 1;
  return jsonb_build_object(
    'parts', parts,
    'done', (select count(*) from jsonb_array_elements(parts) p where (p ->> 'done')::boolean),
    'total', jsonb_array_length(parts),
    'next', nxt);
end $function$;

revoke all on function public.page_parts(uuid) from public, anon, authenticated;

create or replace function public.owner_performance(p_venue uuid, p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v      public.venues%rowtype;
  d      int := case when p_days in (30, 91, 365) then p_days else 30 end;
  today  date := (now() at time zone 'utc')::date;
  g_end  date;
  g_from date;
  c_from date;
  g_now  int; g_prev int;
  v_now  int; v_prev int;
  dirs   int;
  rq     int; rq_held int;
  rule   jsonb := public.free_enquiry_rule();
begin
  v := public.billing_venue(p_venue, false);   -- the owner, or a founder
  select max(day), min(day) into g_end, g_from from public.page_google_days;
  select min(day) into c_from from public.page_counts;

  if g_end is not null then
    select coalesce(sum(impressions), 0) into g_now from public.page_google_days
     where venue_id = v.id and day > g_end - d and day <= g_end;
    if g_from <= g_end - 2 * d + 1 then
      select coalesce(sum(impressions), 0) into g_prev from public.page_google_days
       where venue_id = v.id and day > g_end - 2 * d and day <= g_end - d;
    end if;
  end if;

  select coalesce(sum(n) filter (where kind = 'view' and day > today - d), 0),
         coalesce(sum(n) filter (where kind = 'view' and day > today - 2 * d and day <= today - d), 0),
         coalesce(sum(n) filter (where kind = 'directions' and day > today - d), 0)
    into v_now, v_prev, dirs
    from public.page_counts where venue_id = v.id and day > today - 2 * d;
  if c_from is null or c_from > today - 2 * d + 1 then
    v_prev := null;   -- the counter is newer than the period before
  end if;

  select count(*) filter (where status <> 'held'), count(*) filter (where status = 'held')
    into rq, rq_held
    from public.enquiries
   where venue_id = v.id and status <> 'closed'
     and created_at > now() - make_interval(days => d);

  return jsonb_build_object(
    'days', d,
    'live', coalesce(v.webflow_slug, '') <> '' and v.website_status = 'released',
    'plus', coalesce(v.listing_tier, 'free') = 'verified',
    'google', g_now, 'google_prev', g_prev, 'google_to', g_end,
    'views', v_now, 'views_prev', v_prev, 'views_from', c_from,
    'directions', dirs,
    'requests', rq, 'requests_held', rq_held,
    'free', jsonb_build_object('on', (rule ->> 'on')::boolean,
      'limit', (rule ->> 'limit')::int, 'used', public.free_enquiries_used(v.id)),
    'months', (
      select jsonb_agg(jsonb_build_object(
               'month', to_char(m, 'YYYY-MM-DD'),
               'google', coalesce((select sum(impressions) from public.page_google_days
                                    where venue_id = v.id and day >= m
                                      and day < m + interval '1 month'), 0),
               'views', coalesce((select sum(n) from public.page_counts
                                   where venue_id = v.id and kind = 'view' and day >= m
                                     and day < m + interval '1 month'), 0))
               order by m)
        from (select generate_series(date_trunc('month', today::timestamp) - interval '5 months',
                                     date_trunc('month', today::timestamp),
                                     interval '1 month')::date as m) mm),
    'queries', coalesce((
      select jsonb_agg(jsonb_build_object('q', q.query, 'n', q.impressions)
                       order by q.impressions desc, q.query)
        from (select * from public.page_google_queries
               where venue_id = v.id
               order by impressions desc, query limit 5) q), '[]'::jsonb),
    'latest', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', e.created_at,
               'status', case when e.status = 'held' then 'held'
                              when e.status in ('sent', 'passed') then 'sent'
                              else 'sending' end,
               'what', case when e.status = 'held' then null else nullif(concat_ws(', ',
                         case when coalesce(e.want, 'other') <> 'other'
                              then initcap(replace(e.want, '_', ' ')) end,
                         case when e.people > 1 then e.people || ' people'
                              when e.people = 1 then 'just one person' end,
                         nullif(btrim(e.dates), '')), '') end)
               order by e.created_at desc)
        from (select * from public.enquiries
               where venue_id = v.id and status <> 'closed'
               order by created_at desc limit 3) e), '[]'::jsonb),
    'parts', public.page_parts(v.id));
end $function$;

revoke all on function public.owner_performance(uuid, int) from public, anon;
grant execute on function public.owner_performance(uuid, int) to authenticated;

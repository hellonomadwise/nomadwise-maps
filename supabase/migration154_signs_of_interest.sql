-- Migration 154: signs of interest, in one place.
--
-- Jonathan, 7 Oct 2026, looking at the notices on his phone: a claim
-- page opened from a listing, and "Circles House just created an
-- account" (a business making an ordinary account on the map, which is
-- not a claim). "I'm just thinking about these different routes...
-- and how we can create a system that either captures or engages with
-- them... within the admin area, in a super clear way, look at these
-- scenarios and go, right, how do we address this?"
--
-- Outreach gets a "Signs of interest" view: every such scenario as a
-- row, with how many spaces stand there now, what we know about them
-- and the one thing to do. Most of the numbers exist already (the
-- path of migrations 148 to 153). Two are new here:
--   * "signed_up": an account made on the map in the last 120 days
--     whose name or address is plainly a listed, unclaimed space's
--     (the address on the space's own website, an address at its
--     website's own domain, or the space's name as the account's name
--     or as the address's domain). Never a public mail domain alone.
--   * "form_begun": the spaces whose claim form was begun and left,
--     with the address typed into it (a part of "looked at the claim
--     page").
-- When a new account matches a space the phone hears of it within the
-- half hour, in a notice of its own.
-- A template is added for writing to them. Nothing is sent by itself.
--
-- And where a claim page visitor was (Jonathan, 7 Oct 2026: "if they
-- are in Chiang Mai and looking in Chiang Mai, it's most likely...
-- the actual owner. Whereas if someone in Canada is looking at Yellow
-- Coworking, then it's less likely... I would like the information to
-- take account of that"). The app tells claim_opened() the visitor's
-- rough place (country and city of the internet connection, never an
-- address); it is judged against the space (its own area, its
-- country, another country), said in the phone notice, kept per
-- visit, shown on the look in Outreach, and the nearer looks come
-- first.

alter table public.space_contacts
  add column if not exists signup_done_at timestamptz;
  -- "Done for now" on an account that matches the space.

-- A name in small plain letters: "Caf" + e-acute + " Joyeux" reads as
-- "cafe joyeux". (The letters are written as codes so this file stays
-- in plain characters.)
create or replace function public.name_plain(p text)
returns text language sql immutable as $$
  select translate(lower(coalesce(p, '')),
    U&'\00e1\00c1\00e0\00c0\00e2\00c2\00e4\00c4\00e3\00c3\00e5\00c5\0101\0100\0103\0102\0105\0104\00e7\00c7\0107\0106\010d\010c\010f\010e\0111\0110\00e9\00c9\00e8\00c8\00ea\00ca\00eb\00cb\0113\0112\0117\0116\0119\0118\011b\011a\011f\011e\00ed\00cd\00ec\00cc\00ee\00ce\00ef\00cf\012b\012a\0131\0049\0142\0141\00f1\00d1\0144\0143\0148\0147\00f3\00d3\00f2\00d2\00f4\00d4\00f6\00d6\00f5\00d5\00f8\00d8\014d\014c\0151\0150\0159\0158\015b\015a\0161\0160\015f\015e\0165\0164\0163\0162\00fa\00da\00f9\00d9\00fb\00db\00fc\00dc\016b\016a\016f\016e\0171\0170\00fd\00dd\00ff\0178\017e\017d\017a\0179\017c\017b',
    'aaaaaaaaaaaaaaaaaaccccccddddeeeeeeeeeeeeeeeeggiiiiiiiiiiiillnnnnnnoooooooooooooooorrssssssttttuuuuuuuuuuuuuuyyyyzzzzzz');
$$;

-- Letters and digits only, in small letters: "Circles House" and
-- "circleshouse" are the same name.
create or replace function public.name_squash(p text)
returns text language sql immutable as $$
  select regexp_replace(public.name_plain(p), '[^a-z0-9]+', '', 'g');
$$;

-- A mail domain anyone can have an address at: it says nothing about
-- which business the person belongs to.
create or replace function public.mail_is_public(p_domain text)
returns boolean language sql immutable as $$
  select coalesce(btrim(p_domain), '') = ''
      or lower(btrim(p_domain)) ~ ('^('
         || '(gmail|googlemail|yahoo|ymail|rocketmail|hotmail|outlook|live|msn|icloud|aol|proton|protonmail|gmx|yandex|zoho|zohomail|fastmail|tutanota|tuta|tutamail|naver|hanmail|daum|qq|163|126|sina|foxmail|rediffmail|mail|email|inbox|seznam|wp|o2|interia|onet|libero|virgilio|bluewin|hushmail|mailbox|posteo|pobox|usa|europe|consultant|post)[.][a-z]{2,3}([.][a-z]{2})?'
         || '|(me|mac|hey|duck|sky|rogers|shaw|bellsouth|cox|earthlink|juno|optonline|charter|telus|talktalk|ntlworld|blueyonder|virginmedia)[.](com|net|ca|co[.]uk)'
         || '|pm[.]me|web[.]de|t-online[.]de|freenet[.]de|arcor[.]de'
         || '|(orange|free|wanadoo|sfr|laposte|neuf|bbox)[.](fr|net)'
         || '|btinternet[.]com|(comcast|verizon|att|sbcglobal|bigpond|optusnet|xtra|telenet|skynet|ziggo|kpnmail|home|planet|chello)[.](net|com|be|nl|com[.]au|net[.]au|co[.]nz)'
         || '|(bk|list|internet|rambler)[.]ru|ukr[.]net|passmail[.]net|privaterelay[.]appleid[.]com'
         || ')$');
$$;

-- The host of a website as it is written in a listing ("cafe.com",
-- " https://www.Cafe.com/menu"), without "www."; null when what is
-- written is not a web address.
create or replace function public.site_host(p_url text)
returns text language sql immutable as $$
  select case when s.h ~ '^[a-z0-9-]+([.][a-z0-9-]+)+$' then s.h end
    from (select regexp_replace(regexp_replace(
                   lower(coalesce(substring(btrim(coalesce(p_url, ''))
                     from '^(?:[A-Za-z][A-Za-z0-9+.-]*://)?(?:[^/?#@[:space:]]*@)?([^/?#:[:space:]]+)'), '')),
                   '^www[.]', ''), '[.]+$', '') as h) s;
$$;

-- ------------------------------------------------ accounts that are a space's
-- One row per account made in the last p_days that matches a listed,
-- unclaimed space, with how it matches: 'address' (the address on the
-- space's own website), 'website' (an address at the website's own
-- domain), 'name' (the account is named as the space) or 'domain'
-- (the address's domain is the space's name). Ours, and people who
-- have claimed anything, are left out.
create or replace function public.signup_space_matches(p_days integer default 120)
returns table (
  user_id      uuid,
  email        text,
  display_name text,
  signed_up_at timestamptz,
  venue_id     uuid,
  how          text
) language sql stable security definer set search_path = public as $$
  with team as materialized (
    -- our own addresses ("name+anything@" is the same inbox as "name@")
    select distinct regexp_replace(lower(btrim(a.email)), '[+][^@]*@', '@') as e
      from auth.users a
      join public.profiles p on p.id = a.id
     where coalesce(p.is_admin, false) or p.cohort = 'team'
  ),
  theirs as materialized (
    -- addresses that have claimed something, or own a page
    select lower(btrim(k.owner_email)) as e
      from public.listing_claims k
     where k.status in ('paid', 'free', 'free_pending', 'awaiting_approval')
       and btrim(coalesce(k.owner_email, '')) <> ''
    union
    select lower(btrim(o.listing_owner_email))
      from public.venues o
     where btrim(coalesce(o.listing_owner_email, '')) <> ''
  ),
  u as materialized (
    select z.*,
           public.name_squash(split_part(z.dom, '.', 1)) as dom_sq,
           public.mail_is_public(z.dom) as pub,
           -- an account never given a name is named after its address,
           -- and "coffeeshop" from coffeeshop@gmail.com says less
           (z.name_sq = public.name_squash(split_part(z.email, '@', 1))) as handle
      from (
        select p.id,
               lower(btrim(a.email)) as email,
               nullif(btrim(p.display_name), '') as display_name,
               public.name_squash(p.display_name) as name_sq,
               split_part(lower(btrim(a.email)), '@', 2) as dom,
               coalesce(a.created_at, p.created_at) as at
          from public.profiles p
          join auth.users a on a.id = p.id
         where coalesce(a.created_at, p.created_at)
                 > now() - make_interval(days => greatest(1, least(coalesce(p_days, 120), 730)))
           and coalesce(btrim(a.email), '') <> ''
           and coalesce(p.cohort, '') <> 'team'
           and not coalesce(p.is_admin, false)
           -- our own test accounts (as migration 149 tells them)
           and lower(btrim(a.email)) not like '%@nomadwise.io'
           and coalesce(btrim(p.display_name), '') !~* '^test([[:space:]]+test)?$'
      ) z
     where not exists (select 1 from team t
                        where t.e = regexp_replace(z.email, '[+][^@]*@', '@'))
       -- they have not claimed anything, and own nothing
       and not exists (select 1 from theirs c where c.e = z.email)
  ),
  v as materialized (
    select y.*,
           -- a website or a name shared by many spaces (a chain) does
           -- not say which of them the account belongs to
           count(*) over (partition by y.host) as host_n,
           count(*) over (partition by y.name_sq) as name_n
      from (
        select x.id,
               public.name_squash(x.name) as name_sq,
               -- a name of two words or more: one word ("Charlie") is
               -- too easily a person's own name
               (btrim(x.name) ~ '[^[:space:]][[:space:]]+[^[:space:]]') as two_words,
               -- in plain letters once its accents are off: squashing
               -- drops every other letter, and what is left can match
               -- by accident
               (public.name_plain(x.name) ~ '^[ -~]+$') as plain,
               public.site_host(x.website) as host,
               -- the website is the space's own, not a page deep inside
               -- somebody else's (a hotel group's, a town's)
               (btrim(coalesce(x.website, '')) ~
                  '^([A-Za-z][A-Za-z0-9+.-]*://)?[^/?#]+(/[^/?#]*)?/?([?#].*)?$') as own_site,
               coalesce(x.contact_emails, '{}') as emails
          from public.venues x
         where x.webflow_cms_id is not null
           and coalesce(x.website_status, '') <> 'retired'
           and coalesce(x.business_status, '') <> 'CLOSED_PERMANENTLY'
           and btrim(coalesce(x.listing_owner_email, '')) = ''
           and coalesce(x.listing_tier, 'free') <> 'verified'
      ) y
     -- a claim that went through, or waits for our decision
     where not exists (select 1 from public.listing_claims k
                        where k.venue_id = y.id
                          and k.status in ('free_pending', 'awaiting_approval', 'paid', 'free'))
  ),
  m as (
    select u.id as user_id, u.email, u.display_name, u.at, a.id as venue_id,
           'address'::text as how, 1 as rank
      from (select v.id, lower(btrim(e.addr)) as addr,
                   count(*) over (partition by lower(btrim(e.addr))) as addr_n
              from v
             cross join lateral unnest(v.emails) as e(addr)) a
      join u on u.email = a.addr
     where a.addr_n <= 3
    union all
    -- (a "website" that is a profile on somebody else's site, or a
    -- university's or a government's, says nothing about the address)
    select u.id, u.email, u.display_name, u.at, v.id, 'website', 2
      from u
      join v on v.host = u.dom
     where not u.pub and v.host_n <= 3 and v.own_site
       and v.host !~ '(^|[.])(instagram|facebook|fb|linktr|linktree|tiktok|twitter|x|youtube|google|wa|whatsapp|bit|wixsite|wix|business|squarespace|webflow|wordpress|blogspot|weebly|godaddysites|carrd|beacons|taplink|booking|tripadvisor|airbnb|hostelworld|agoda|yelp|foursquare|notion|canva|myshopify|strikingly|mystrikingly|linkin|lnk|bio|heylink|msha|komi|campsite|jimdosite|jimdofree|site123|ueniweb|glideapp|github|medium|substack|line|telegram|t)[.][a-z.]+$'
       and v.host !~ '[.](edu|gov|ac|mil)([.][a-z]{2})?$'
    union all
    select u.id, u.email, u.display_name, u.at, v.id, 'name', 3
      from u
      join v on v.name_sq = u.name_sq
     where v.plain and v.two_words and v.name_n <= 3
       and length(v.name_sq) >= case when u.handle then 12 else 8 end
    union all
    select u.id, u.email, u.display_name, u.at, v.id, 'domain', 4
      from u
      join v on v.name_sq = u.dom_sq
     where v.plain and v.name_n <= 3 and not u.pub
       -- (one word has to be a long one: "Basecamp" the cafe is not
       -- basecamp.com the company)
       and length(v.name_sq) >= case when v.two_words then 6 else 12 end
  )
  select distinct on (m.user_id)
         m.user_id, m.email, m.display_name, m.at, m.venue_id, m.how
    from m
   order by m.user_id, m.rank, m.venue_id;
$$;
revoke all on function public.signup_space_matches(integer) from public, anon, authenticated;
grant execute on function public.signup_space_matches(integer) to service_role;

-- The spaces with such an account still to follow up, each with one
-- of its lines in Outreach: nothing written to the space since the
-- account was made, and no "Done for now" since.
create or replace function public.signup_lines()
returns table (
  contact_id   uuid,
  venue_id     uuid,
  email        text,
  display_name text,
  signed_up_at timestamptz,
  how          text
) language sql stable security definer set search_path = public as $$
  select distinct on (m.venue_id)
         c.id, m.venue_id, m.email, m.display_name, m.signed_up_at, m.how
    from public.signup_space_matches(120) m
    join lateral (
           select s.id
             from public.space_contacts s
            where s.venue_id = m.venue_id and not s.is_test
              and s.stage in ('new', 'contacted', 'replied')
            order by (s.email is not null) desc, s.created_at, s.id
            limit 1) c on true
   where not exists (select 1 from public.space_contacts s
                      where s.venue_id = m.venue_id and not s.is_test
                        and (s.last_out_at >= m.signed_up_at
                             or s.signup_done_at >= m.signed_up_at))
   order by m.venue_id, m.signed_up_at desc;
$$;
revoke all on function public.signup_lines() from public, anon, authenticated;
grant execute on function public.signup_lines() to service_role;

-- Which accounts the half-hourly look below has dealt with already.
create table if not exists public.signup_match_seen (
  user_id  uuid primary key,
  venue_id uuid,
  at       timestamptz not null default now()
);
alter table public.signup_match_seen enable row level security;
-- (no policy: read and written only by the function below)

-- Every half hour: a newly matched space gets its line in Outreach,
-- and the phone hears of it when the account is of the last two days.
-- Making an account never waits on any of this: the notice for the
-- account itself (migration 25) is left exactly as it is.
create or replace function public.signup_match_sync()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  n integer := 0;
begin
  for r in select m.user_id, m.venue_id, m.display_name, m.signed_up_at, m.how, v.name
             from public.signup_space_matches(120) m
             join public.venues v on v.id = m.venue_id
            where not exists (select 1 from public.signup_match_seen s
                               where s.user_id = m.user_id) loop
    begin
      insert into public.signup_match_seen (user_id, venue_id)
      values (r.user_id, r.venue_id)
      on conflict (user_id) do nothing;
      -- (another run got there first: it is theirs to tell)
      if not found then
        continue;
      end if;
      perform public.outreach_line_for_venue(r.venue_id);
      n := n + 1;
      if r.signed_up_at > now() - interval '2 days' then
        perform public.notify_phone(
          'A new account looks like a listed space',
          coalesce(r.display_name, 'Someone') || ' made an account on the map. It looks like the listed space '
            || r.name || ', which nobody has claimed ('
            || case r.how when 'address' then 'the address is the one on the space''s website'
                          when 'website' then 'the address is at the space''s own website'
                          when 'name' then 'the account has the space''s name'
                          else 'the address''s domain is the space''s name' end
            || ').'
            || case when exists (select 1 from public.signup_lines() s
                                  where s.venue_id = r.venue_id)
                    then ' It is under Signs of interest in Outreach.' else '' end,
          'wave');
      end if;
    exception when others then
      null;
    end;
  end loop;
  return n;
end $$;
revoke all on function public.signup_match_sync() from public, anon, authenticated;
grant execute on function public.signup_match_sync() to service_role;

-- ------------------------------------------------ where a claim page visitor was
-- The time zone a device's clock is set to, and the country it
-- belongs to. A VPN moves where the connection seems to be; it does
-- not move the clock. (From the public time zone list.)
create table if not exists public.tz_countries (
  tz  text primary key,
  iso text not null
);
alter table public.tz_countries enable row level security;
insert into public.tz_countries (tz, iso) values
  ('Africa/Abidjan','CI'),('Africa/Accra','GH'),('Africa/Addis_Ababa','ET'),
  ('Africa/Algiers','DZ'),('Africa/Asmara','ER'),('Africa/Asmera','ER'),('Africa/Bamako','ML'),
  ('Africa/Bangui','CF'),('Africa/Banjul','GM'),('Africa/Bissau','GW'),('Africa/Blantyre','MW'),
  ('Africa/Brazzaville','CG'),('Africa/Bujumbura','BI'),('Africa/Cairo','EG'),
  ('Africa/Casablanca','MA'),('Africa/Ceuta','ES'),('Africa/Conakry','GN'),('Africa/Dakar','SN'),
  ('Africa/Dar_es_Salaam','TZ'),('Africa/Djibouti','DJ'),('Africa/Douala','CM'),
  ('Africa/El_Aaiun','EH'),('Africa/Freetown','SL'),('Africa/Gaborone','BW'),
  ('Africa/Harare','ZW'),('Africa/Johannesburg','ZA'),('Africa/Juba','SS'),
  ('Africa/Kampala','UG'),('Africa/Khartoum','SD'),('Africa/Kigali','RW'),
  ('Africa/Kinshasa','CD'),('Africa/Lagos','NG'),('Africa/Libreville','GA'),('Africa/Lome','TG'),
  ('Africa/Luanda','AO'),('Africa/Lubumbashi','CD'),('Africa/Lusaka','ZM'),('Africa/Malabo','GQ'),
  ('Africa/Maputo','MZ'),('Africa/Maseru','LS'),('Africa/Mbabane','SZ'),('Africa/Mogadishu','SO'),
  ('Africa/Monrovia','LR'),('Africa/Nairobi','KE'),('Africa/Ndjamena','TD'),
  ('Africa/Niamey','NE'),('Africa/Nouakchott','MR'),('Africa/Ouagadougou','BF'),
  ('Africa/Porto-Novo','BJ'),('Africa/Sao_Tome','ST'),('Africa/Timbuktu','ML'),
  ('Africa/Tripoli','LY'),('Africa/Tunis','TN'),('Africa/Windhoek','NA'),('America/Adak','US'),
  ('America/Anchorage','US'),('America/Anguilla','AI'),('America/Antigua','AG'),
  ('America/Araguaina','BR'),('America/Argentina/Buenos_Aires','AR'),
  ('America/Argentina/Catamarca','AR'),('America/Argentina/ComodRivadavia','AR'),
  ('America/Argentina/Cordoba','AR'),('America/Argentina/Jujuy','AR'),
  ('America/Argentina/La_Rioja','AR'),('America/Argentina/Mendoza','AR'),
  ('America/Argentina/Rio_Gallegos','AR'),('America/Argentina/Salta','AR'),
  ('America/Argentina/San_Juan','AR'),('America/Argentina/San_Luis','AR'),
  ('America/Argentina/Tucuman','AR'),('America/Argentina/Ushuaia','AR'),('America/Aruba','AW'),
  ('America/Asuncion','PY'),('America/Atikokan','CA'),('America/Atka','US'),
  ('America/Bahia','BR'),('America/Bahia_Banderas','MX'),('America/Barbados','BB'),
  ('America/Belem','BR'),('America/Belize','BZ'),('America/Blanc-Sablon','CA'),
  ('America/Boa_Vista','BR'),('America/Bogota','CO'),('America/Boise','US'),
  ('America/Buenos_Aires','AR'),('America/Cambridge_Bay','CA'),('America/Campo_Grande','BR'),
  ('America/Cancun','MX'),('America/Caracas','VE'),('America/Catamarca','AR'),
  ('America/Cayenne','GF'),('America/Cayman','KY'),('America/Chicago','US'),
  ('America/Chihuahua','MX'),('America/Ciudad_Juarez','MX'),('America/Coral_Harbour','CA'),
  ('America/Cordoba','AR'),('America/Costa_Rica','CR'),('America/Coyhaique','CL'),
  ('America/Creston','CA'),('America/Cuiaba','BR'),('America/Curacao','CW'),
  ('America/Danmarkshavn','GL'),('America/Dawson','CA'),('America/Dawson_Creek','CA'),
  ('America/Denver','US'),('America/Detroit','US'),('America/Dominica','DM'),
  ('America/Edmonton','CA'),('America/Eirunepe','BR'),('America/El_Salvador','SV'),
  ('America/Ensenada','MX'),('America/Fort_Nelson','CA'),('America/Fort_Wayne','US'),
  ('America/Fortaleza','BR'),('America/Glace_Bay','CA'),('America/Godthab','GL'),
  ('America/Goose_Bay','CA'),('America/Grand_Turk','TC'),('America/Grenada','GD'),
  ('America/Guadeloupe','GP'),('America/Guatemala','GT'),('America/Guayaquil','EC'),
  ('America/Guyana','GY'),('America/Halifax','CA'),('America/Havana','CU'),
  ('America/Hermosillo','MX'),('America/Indiana/Indianapolis','US'),('America/Indiana/Knox','US'),
  ('America/Indiana/Marengo','US'),('America/Indiana/Petersburg','US'),
  ('America/Indiana/Tell_City','US'),('America/Indiana/Vevay','US'),
  ('America/Indiana/Vincennes','US'),('America/Indiana/Winamac','US'),
  ('America/Indianapolis','US'),('America/Inuvik','CA'),('America/Iqaluit','CA'),
  ('America/Jamaica','JM'),('America/Jujuy','AR'),('America/Juneau','US'),
  ('America/Kentucky/Louisville','US'),('America/Kentucky/Monticello','US'),
  ('America/Knox_IN','US'),('America/Kralendijk','BQ'),('America/La_Paz','BO'),
  ('America/Lima','PE'),('America/Los_Angeles','US'),('America/Louisville','US'),
  ('America/Lower_Princes','SX'),('America/Maceio','BR'),('America/Managua','NI'),
  ('America/Manaus','BR'),('America/Marigot','MF'),('America/Martinique','MQ'),
  ('America/Matamoros','MX'),('America/Mazatlan','MX'),('America/Mendoza','AR'),
  ('America/Menominee','US'),('America/Merida','MX'),('America/Metlakatla','US'),
  ('America/Mexico_City','MX'),('America/Miquelon','PM'),('America/Moncton','CA'),
  ('America/Monterrey','MX'),('America/Montevideo','UY'),('America/Montreal','CA'),
  ('America/Montserrat','MS'),('America/Nassau','BS'),('America/New_York','US'),
  ('America/Nipigon','CA'),('America/Nome','US'),('America/Noronha','BR'),
  ('America/North_Dakota/Beulah','US'),('America/North_Dakota/Center','US'),
  ('America/North_Dakota/New_Salem','US'),('America/Nuuk','GL'),('America/Ojinaga','MX'),
  ('America/Panama','PA'),('America/Pangnirtung','CA'),('America/Paramaribo','SR'),
  ('America/Phoenix','US'),('America/Port-au-Prince','HT'),('America/Port_of_Spain','TT'),
  ('America/Porto_Acre','BR'),('America/Porto_Velho','BR'),('America/Puerto_Rico','PR'),
  ('America/Punta_Arenas','CL'),('America/Rainy_River','CA'),('America/Rankin_Inlet','CA'),
  ('America/Recife','BR'),('America/Regina','CA'),('America/Resolute','CA'),
  ('America/Rio_Branco','BR'),('America/Rosario','AR'),('America/Santa_Isabel','MX'),
  ('America/Santarem','BR'),('America/Santiago','CL'),('America/Santo_Domingo','DO'),
  ('America/Sao_Paulo','BR'),('America/Scoresbysund','GL'),('America/Shiprock','US'),
  ('America/Sitka','US'),('America/St_Barthelemy','BL'),('America/St_Johns','CA'),
  ('America/St_Kitts','KN'),('America/St_Lucia','LC'),('America/St_Thomas','VI'),
  ('America/St_Vincent','VC'),('America/Swift_Current','CA'),('America/Tegucigalpa','HN'),
  ('America/Thule','GL'),('America/Thunder_Bay','CA'),('America/Tijuana','MX'),
  ('America/Toronto','CA'),('America/Tortola','VG'),('America/Vancouver','CA'),
  ('America/Virgin','VI'),('America/Whitehorse','CA'),('America/Winnipeg','CA'),
  ('America/Yakutat','US'),('America/Yellowknife','CA'),('Antarctica/Casey','AQ'),
  ('Antarctica/Davis','AQ'),('Antarctica/DumontDUrville','AQ'),('Antarctica/Macquarie','AU'),
  ('Antarctica/Mawson','AQ'),('Antarctica/McMurdo','AQ'),('Antarctica/Palmer','AQ'),
  ('Antarctica/Rothera','AQ'),('Antarctica/South_Pole','AQ'),('Antarctica/Syowa','AQ'),
  ('Antarctica/Troll','AQ'),('Antarctica/Vostok','AQ'),('Arctic/Longyearbyen','SJ'),
  ('Asia/Aden','YE'),('Asia/Almaty','KZ'),('Asia/Amman','JO'),('Asia/Anadyr','RU'),
  ('Asia/Aqtau','KZ'),('Asia/Aqtobe','KZ'),('Asia/Ashgabat','TM'),('Asia/Ashkhabad','TM'),
  ('Asia/Atyrau','KZ'),('Asia/Baghdad','IQ'),('Asia/Bahrain','BH'),('Asia/Baku','AZ'),
  ('Asia/Bangkok','TH'),('Asia/Barnaul','RU'),('Asia/Beirut','LB'),('Asia/Bishkek','KG'),
  ('Asia/Brunei','BN'),('Asia/Calcutta','IN'),('Asia/Chita','RU'),('Asia/Choibalsan','MN'),
  ('Asia/Chongqing','CN'),('Asia/Chungking','CN'),('Asia/Colombo','LK'),('Asia/Dacca','BD'),
  ('Asia/Damascus','SY'),('Asia/Dhaka','BD'),('Asia/Dili','TL'),('Asia/Dubai','AE'),
  ('Asia/Dushanbe','TJ'),('Asia/Famagusta','CY'),('Asia/Gaza','PS'),('Asia/Harbin','CN'),
  ('Asia/Hebron','PS'),('Asia/Ho_Chi_Minh','VN'),('Asia/Hong_Kong','HK'),('Asia/Hovd','MN'),
  ('Asia/Irkutsk','RU'),('Asia/Istanbul','TR'),('Asia/Jakarta','ID'),('Asia/Jayapura','ID'),
  ('Asia/Jerusalem','IL'),('Asia/Kabul','AF'),('Asia/Kamchatka','RU'),('Asia/Karachi','PK'),
  ('Asia/Kashgar','CN'),('Asia/Kathmandu','NP'),('Asia/Katmandu','NP'),('Asia/Khandyga','RU'),
  ('Asia/Kolkata','IN'),('Asia/Krasnoyarsk','RU'),('Asia/Kuala_Lumpur','MY'),
  ('Asia/Kuching','MY'),('Asia/Kuwait','KW'),('Asia/Macao','MO'),('Asia/Macau','MO'),
  ('Asia/Magadan','RU'),('Asia/Makassar','ID'),('Asia/Manila','PH'),('Asia/Muscat','OM'),
  ('Asia/Nicosia','CY'),('Asia/Novokuznetsk','RU'),('Asia/Novosibirsk','RU'),('Asia/Omsk','RU'),
  ('Asia/Oral','KZ'),('Asia/Phnom_Penh','KH'),('Asia/Pontianak','ID'),('Asia/Pyongyang','KP'),
  ('Asia/Qatar','QA'),('Asia/Qostanay','KZ'),('Asia/Qyzylorda','KZ'),('Asia/Rangoon','MM'),
  ('Asia/Riyadh','SA'),('Asia/Saigon','VN'),('Asia/Sakhalin','RU'),('Asia/Samarkand','UZ'),
  ('Asia/Seoul','KR'),('Asia/Shanghai','CN'),('Asia/Singapore','SG'),('Asia/Srednekolymsk','RU'),
  ('Asia/Taipei','TW'),('Asia/Tashkent','UZ'),('Asia/Tbilisi','GE'),('Asia/Tehran','IR'),
  ('Asia/Tel_Aviv','IL'),('Asia/Thimbu','BT'),('Asia/Thimphu','BT'),('Asia/Tokyo','JP'),
  ('Asia/Tomsk','RU'),('Asia/Ujung_Pandang','ID'),('Asia/Ulaanbaatar','MN'),
  ('Asia/Ulan_Bator','MN'),('Asia/Urumqi','CN'),('Asia/Ust-Nera','RU'),('Asia/Vientiane','LA'),
  ('Asia/Vladivostok','RU'),('Asia/Yakutsk','RU'),('Asia/Yangon','MM'),
  ('Asia/Yekaterinburg','RU'),('Asia/Yerevan','AM'),('Atlantic/Azores','PT'),
  ('Atlantic/Bermuda','BM'),('Atlantic/Canary','ES'),('Atlantic/Cape_Verde','CV'),
  ('Atlantic/Faeroe','FO'),('Atlantic/Faroe','FO'),('Atlantic/Jan_Mayen','NO'),
  ('Atlantic/Madeira','PT'),('Atlantic/Reykjavik','IS'),('Atlantic/South_Georgia','GS'),
  ('Atlantic/St_Helena','SH'),('Atlantic/Stanley','FK'),('Australia/ACT','AU'),
  ('Australia/Adelaide','AU'),('Australia/Brisbane','AU'),('Australia/Broken_Hill','AU'),
  ('Australia/Canberra','AU'),('Australia/Currie','AU'),('Australia/Darwin','AU'),
  ('Australia/Eucla','AU'),('Australia/Hobart','AU'),('Australia/LHI','AU'),
  ('Australia/Lindeman','AU'),('Australia/Lord_Howe','AU'),('Australia/Melbourne','AU'),
  ('Australia/NSW','AU'),('Australia/North','AU'),('Australia/Perth','AU'),
  ('Australia/Queensland','AU'),('Australia/South','AU'),('Australia/Sydney','AU'),
  ('Australia/Tasmania','AU'),('Australia/Victoria','AU'),('Australia/West','AU'),
  ('Australia/Yancowinna','AU'),('Brazil/Acre','BR'),('Brazil/DeNoronha','BR'),
  ('Brazil/East','BR'),('Brazil/West','BR'),('Canada/Atlantic','CA'),('Canada/Central','CA'),
  ('Canada/Eastern','CA'),('Canada/Mountain','CA'),('Canada/Newfoundland','CA'),
  ('Canada/Pacific','CA'),('Canada/Saskatchewan','CA'),('Canada/Yukon','CA'),
  ('Chile/Continental','CL'),('Chile/EasterIsland','CL'),('Europe/Amsterdam','NL'),
  ('Europe/Andorra','AD'),('Europe/Astrakhan','RU'),('Europe/Athens','GR'),
  ('Europe/Belfast','GB'),('Europe/Belgrade','RS'),('Europe/Berlin','DE'),
  ('Europe/Bratislava','SK'),('Europe/Brussels','BE'),('Europe/Bucharest','RO'),
  ('Europe/Budapest','HU'),('Europe/Busingen','DE'),('Europe/Chisinau','MD'),
  ('Europe/Copenhagen','DK'),('Europe/Dublin','IE'),('Europe/Gibraltar','GI'),
  ('Europe/Guernsey','GG'),('Europe/Helsinki','FI'),('Europe/Isle_of_Man','IM'),
  ('Europe/Istanbul','TR'),('Europe/Jersey','JE'),('Europe/Kaliningrad','RU'),
  ('Europe/Kiev','UA'),('Europe/Kirov','RU'),('Europe/Kyiv','UA'),('Europe/Lisbon','PT'),
  ('Europe/Ljubljana','SI'),('Europe/London','GB'),('Europe/Luxembourg','LU'),
  ('Europe/Madrid','ES'),('Europe/Malta','MT'),('Europe/Mariehamn','AX'),('Europe/Minsk','BY'),
  ('Europe/Monaco','MC'),('Europe/Moscow','RU'),('Europe/Nicosia','CY'),('Europe/Oslo','NO'),
  ('Europe/Paris','FR'),('Europe/Podgorica','ME'),('Europe/Prague','CZ'),('Europe/Riga','LV'),
  ('Europe/Rome','IT'),('Europe/Samara','RU'),('Europe/San_Marino','SM'),('Europe/Sarajevo','BA'),
  ('Europe/Saratov','RU'),('Europe/Simferopol','UA'),('Europe/Skopje','MK'),('Europe/Sofia','BG'),
  ('Europe/Stockholm','SE'),('Europe/Tallinn','EE'),('Europe/Tirane','AL'),
  ('Europe/Tiraspol','MD'),('Europe/Ulyanovsk','RU'),('Europe/Uzhgorod','UA'),
  ('Europe/Vaduz','LI'),('Europe/Vatican','VA'),('Europe/Vienna','AT'),('Europe/Vilnius','LT'),
  ('Europe/Volgograd','RU'),('Europe/Warsaw','PL'),('Europe/Zagreb','HR'),
  ('Europe/Zaporozhye','UA'),('Europe/Zurich','CH'),('Indian/Antananarivo','MG'),
  ('Indian/Chagos','IO'),('Indian/Christmas','CX'),('Indian/Cocos','CC'),('Indian/Comoro','KM'),
  ('Indian/Kerguelen','TF'),('Indian/Mahe','SC'),('Indian/Maldives','MV'),
  ('Indian/Mauritius','MU'),('Indian/Mayotte','YT'),('Indian/Reunion','RE'),
  ('Mexico/BajaNorte','MX'),('Mexico/BajaSur','MX'),('Mexico/General','MX'),('Pacific/Apia','WS'),
  ('Pacific/Auckland','NZ'),('Pacific/Bougainville','PG'),('Pacific/Chatham','NZ'),
  ('Pacific/Chuuk','FM'),('Pacific/Easter','CL'),('Pacific/Efate','VU'),
  ('Pacific/Enderbury','KI'),('Pacific/Fakaofo','TK'),('Pacific/Fiji','FJ'),
  ('Pacific/Funafuti','TV'),('Pacific/Galapagos','EC'),('Pacific/Gambier','PF'),
  ('Pacific/Guadalcanal','SB'),('Pacific/Guam','GU'),('Pacific/Honolulu','US'),
  ('Pacific/Johnston','US'),('Pacific/Kanton','KI'),('Pacific/Kiritimati','KI'),
  ('Pacific/Kosrae','FM'),('Pacific/Kwajalein','MH'),('Pacific/Majuro','MH'),
  ('Pacific/Marquesas','PF'),('Pacific/Midway','UM'),('Pacific/Nauru','NR'),('Pacific/Niue','NU'),
  ('Pacific/Norfolk','NF'),('Pacific/Noumea','NC'),('Pacific/Pago_Pago','AS'),
  ('Pacific/Palau','PW'),('Pacific/Pitcairn','PN'),('Pacific/Pohnpei','FM'),
  ('Pacific/Ponape','FM'),('Pacific/Port_Moresby','PG'),('Pacific/Rarotonga','CK'),
  ('Pacific/Saipan','MP'),('Pacific/Samoa','AS'),('Pacific/Tahiti','PF'),('Pacific/Tarawa','KI'),
  ('Pacific/Tongatapu','TO'),('Pacific/Truk','FM'),('Pacific/Wake','UM'),('Pacific/Wallis','WF'),
  ('Pacific/Yap','FM'),('US/Alaska','US'),('US/Aleutian','US'),('US/Arizona','US'),
  ('US/Central','US'),('US/East-Indiana','US'),('US/Eastern','US'),('US/Hawaii','US'),
  ('US/Indiana-Starke','US'),('US/Michigan','US'),('US/Mountain','US'),('US/Pacific','US'),
  ('US/Samoa','AS')
on conflict (tz) do nothing;

-- One row per visit to a space's claim page: the rough place of the
-- visitor's connection, the country of the device's clock, and how
-- that stands to the space. No address, no coordinates.
create table if not exists public.claim_visit_geo (
  visit    text primary key,
  anon_id  text,
  venue_id uuid references public.venues(id) on delete cascade,
  at       timestamptz not null default now(),
  cc       text,                -- country of the connection
  country  text,
  city     text,
  km       integer,             -- from the space, as the connection sees it
  clock_cc text,                -- country of the device's clock
  near     text check (near in ('near', 'country', 'far')),
  src      text check (src in ('ip', 'clock')),  -- judged by the connection or the clock
  dc       boolean not null default false   -- a VPN or a data centre
);
create index if not exists idx_claim_visit_geo_venue
  on public.claim_visit_geo (venue_id, at desc);
alter table public.claim_visit_geo enable row level security;
-- (no policy: read and written only by the functions below)

-- How a visitor's place stands to a space:
--   'near'    the connection is within 60 km of the space, or in a
--             town the space's own address names;
--   'country' the connection, or failing that the device's clock, is
--             in the space's country;
--   'far'     another country;
--   null      not known.
create or replace function public.claim_geo_judge(
  p_venue uuid, p_cc text, p_city text,
  p_lat double precision, p_lng double precision, p_clock_cc text)
returns table (near text, src text, km integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v     record;
  v_iso text;
  cc    text := upper(nullif(btrim(coalesce(p_cc, '')), ''));
  clk   text := upper(nullif(btrim(coalesce(p_clock_cc, '')), ''));
  cty   text := lower(btrim(coalesce(p_city, '')));
begin
  near := null; src := null; km := null;
  select x.lat, x.lng, x.country, x.city, x.neighbourhood into v
    from public.venues x where x.id = p_venue;
  if not found then
    return next; return;
  end if;
  begin
    v_iso := public.pricing_country_iso(v.country);
  exception when others then
    v_iso := null;
  end;
  if p_lat is not null and p_lng is not null and v.lat is not null and v.lng is not null
     and p_lat between -90 and 90 and p_lng between -180 and 180
     and not (p_lat = 0 and p_lng = 0) then
    km := round(6371 * 2 * asin(least(1, sqrt(
            power(sin(radians(v.lat - p_lat) / 2), 2)
            + cos(radians(p_lat)) * cos(radians(v.lat))
              * power(sin(radians(v.lng - p_lng) / 2), 2)))))::integer;
  end if;
  -- (the distance counts only with a town: without one the position
  -- is the middle of the country. And the town's name must stand as a
  -- word of its own in the space's address, in the same country.)
  if cty = '' then
    km := null;
  end if;
  if (km is not null and km <= 60)
     or (length(cty) >= 4 and cc is not null
         and (v_iso is null or cc = v_iso)
         and position(' ' || cty || ' ' in ' ' || regexp_replace(
               lower(coalesce(v.city, '') || ' ' || coalesce(v.neighbourhood, '')),
               '[^a-z0-9]+', ' ', 'g') || ' ') > 0) then
    near := 'near'; src := 'ip';
  elsif v_iso is not null and cc = v_iso then
    near := 'country'; src := 'ip';
  elsif v_iso is not null and clk = v_iso then
    near := 'country'; src := 'clock';
  elsif v_iso is not null and cc is not null then
    near := 'far'; src := 'ip';
  elsif v_iso is not null and clk is not null then
    near := 'far'; src := 'clock';
  end if;
  return next;
end $$;
revoke all on function public.claim_geo_judge(uuid, text, text, double precision, double precision, text)
  from public, anon, authenticated;
grant execute on function public.claim_geo_judge(uuid, text, text, double precision, double precision, text)
  to service_role;

-- A country's name from its code, or the code itself.
create or replace function public.claim_geo_country(p_iso text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select c.name from public.pricing_countries c
                    where c.iso = upper(btrim(p_iso))),
                  nullif(upper(btrim(coalesce(p_iso, ''))), ''));
$$;

-- "Chiang Mai, Thailand"; "Singapore" once, not twice.
create or replace function public.claim_geo_place(p_city text, p_country text)
returns text language sql immutable as $$
  select case when lower(btrim(coalesce(p_city, ''))) = lower(btrim(coalesce(p_country, '')))
              then nullif(btrim(coalesce(p_country, '')), '')
              else nullif(concat_ws(', ', nullif(btrim(coalesce(p_city, '')), ''),
                                          nullif(btrim(coalesce(p_country, '')), '')), '') end;
$$;

-- The same in a sentence, for the phone notice and for Outreach. It
-- is a hint and says so: a connection can be anywhere.
create or replace function public.claim_geo_words(
  p_near text, p_by text, p_city text, p_country text, p_cc text,
  p_clock_cc text, p_dc boolean)
returns text language sql stable security definer set search_path = public as $$
  select btrim(
    case
      when s.place is null and s.clock is null then ''
      when p_near = 'near' then
        'Looking from ' || coalesce(s.place, 'nearby')
        || ', the space''s own area: quite possibly someone from the space.'
      when p_near = 'country' and coalesce(p_by, 'ip') = 'ip' then
        'Looking from ' || coalesce(s.place, 'the same country')
        || ', the same country as the space: could well be someone from the space.'
      when p_near = 'country' then
        case when s.place is null then 'The device''s clock is on '
             else 'The connection shows ' || s.place || ', but the device''s clock is on ' end
        || s.clock || ' time, the space''s country: probably there'
        || case when s.place is null then '.' else ', through a VPN.' end
      when p_near = 'far' then
        case when s.place is null then 'The device''s clock is on ' || s.clock || ' time'
             else 'Looking from ' || s.place end
        || ', another country: less likely to be the owner.'
      else
        case when s.place is null then '' else 'Looking from ' || s.place || '.' end
    end
    -- the clock, when it tells another story than the connection
    || case when s.place is not null and s.clock is not null
                 and not (coalesce(p_near, '') = 'country' and coalesce(p_by, 'ip') = 'clock')
                 and upper(coalesce(p_clock_cc, '')) <> upper(coalesce(p_cc, ''))
            then ' The device''s clock is on ' || s.clock || ' time.' else '' end
    || case when coalesce(p_dc, false) and coalesce(p_by, 'ip') = 'ip' and s.place is not null
            then ' The connection is a VPN or a data centre, so the place may not be theirs.'
            else '' end)
    from (select public.claim_geo_place(p_city, p_country) as place,
                 public.claim_geo_country(p_clock_cc) as clock) s;
$$;
revoke all on function public.claim_geo_words(text, text, text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_geo_words(text, text, text, text, text, text, boolean)
  to service_role;

-- The place to show on a space's look: of the visits in the two weeks
-- up to the latest one, and since we last wrote, the nearest. Our own
-- devices are left out.
create or replace function public.claim_look_geo(p_venue uuid, p_last timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'near', g.near, 'src', g.src, 'km', g.km, 'dc', g.dc, 'at', g.at,
           'place', public.claim_geo_place(g.city, g.country),
           'words', public.claim_geo_words(g.near, g.src, g.city, g.country,
                                           g.cc, g.clock_cc, g.dc))
    from public.claim_visit_geo g
   where g.venue_id = p_venue
     and g.at > coalesce(p_last, now()) - interval '14 days'
     -- only the visits since we last wrote to the space, or set it
     -- aside: an older one is not what brought it back
     and g.at > coalesce((
           select max(greatest(coalesce(s.last_out_at, '-infinity'::timestamptz),
                               coalesce(s.claim_look_done_at, '-infinity'::timestamptz)))
             from public.space_contacts s
            where s.venue_id = p_venue and not s.is_test), '-infinity'::timestamptz)
     and not exists (select 1 from public.team_devices t where t.anon_id = g.anon_id)
   order by case g.near when 'near' then 1 when 'country' then 2
                        when 'far' then 4 else 3 end,
            g.dc, g.at desc
   limit 1;
$$;
revoke all on function public.claim_look_geo(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_look_geo(uuid, timestamptz) to service_role;

-- ------------------------------------------------ the claim page notice
-- As migration 153, and it takes the visitor's rough place from the
-- app: {visit, anon, cc, country, city, lat, lng, tz, dc}. An app
-- from before today sends four things and still works.
drop function if exists public.claim_opened(text, text, text, text);
create or replace function public.claim_opened(
  p_seed text, p_from text, p_referrer text, p_user_agent text,
  p_geo jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  seed   text := nullif(left(trim(coalesce(p_seed, '')), 200), '');
  frm    text := nullif(left(trim(coalesce(p_from, '')), 300), '');
  ref    text := nullif(left(trim(coalesce(p_referrer, '')), 300), '');
  ua     text := nullif(left(trim(coalesce(p_user_agent, '')), 300), '');
  g      jsonb := case when jsonb_typeof(p_geo) = 'object' then p_geo else '{}'::jsonb end;
  v_id   uuid;
  v_name text;
  v_city text;
  what   text;
  whence text;
  recent int;
  g_cc      text;
  g_country text;
  g_city    text;
  g_lat     double precision;
  g_lng     double precision;
  g_clock   text;
  g_dc      boolean;
  g_visit   text;
  g_anon    text;
  g_near    text;
  g_src     text;
  g_km      integer;
  title     text := 'Claim page opened';
  place     text := '';
begin
  insert into public.claim_visits (seed, from_path, referrer, user_agent)
  values (seed, frm, ref, ua);

  select count(*) into recent from public.claim_visits
   where created_at > now() - interval '1 hour';
  if recent > 30 then
    return;
  end if;

  if seed is not null then
    select id, name, city into v_id, v_name, v_city from public.venues
     where webflow_slug = seed or lower(name) = lower(seed)
     order by coalesce(webflow_slug = seed, false) desc,
              (webflow_cms_id is not null) desc, id
     limit 1;
  end if;
  -- The space's line in Outreach, so the visit can be followed up
  -- from there (migration 153). Never in the way of the ping.
  begin
    if v_id is not null then
      perform public.outreach_line_for_venue(v_id);
    end if;
  exception when others then
    null;
  end;

  -- Where the visitor was. Never in the way of the ping either.
  begin
    g_cc := upper(left(btrim(coalesce(g ->> 'cc', '')), 2));
    if g_cc !~ '^[A-Z]{2}$' then
      -- what the server itself saw of the request
      begin
        g_cc := upper(btrim(coalesce(
          current_setting('request.headers', true)::json ->> 'cf-ipcountry', '')));
      exception when others then
        g_cc := '';
      end;
    end if;
    if g_cc !~ '^[A-Z]{2}$' or g_cc in ('XX', 'T1') then
      g_cc := null;
    end if;
    -- (what the visitor's browser sent ends up in a notice: letters,
    -- digits and a few marks only, and not much of it)
    g_country := nullif(left(btrim(regexp_replace(coalesce(g ->> 'country', ''),
                   '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if g_country is null then
      g_country := public.claim_geo_country(g_cc);
    end if;
    g_city := nullif(left(btrim(regexp_replace(coalesce(g ->> 'city', ''),
                '[^[:alnum:] .,''()-]', '', 'g')), 40), '');
    if (g ->> 'lat') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lat := (g ->> 'lat')::double precision;
    end if;
    if (g ->> 'lng') ~ '^-?[0-9]{1,3}([.][0-9]{1,12})?$' then
      g_lng := (g ->> 'lng')::double precision;
    end if;
    select t.iso into g_clock from public.tz_countries t
     where t.tz = left(btrim(coalesce(g ->> 'tz', '')), 64);
    g_dc := coalesce(g ->> 'dc', '') = 'true';
    -- a town says nothing without its country
    if g_cc is null then
      g_city := null; g_country := null; g_lat := null; g_lng := null;
    end if;
    g_visit := nullif(left(btrim(coalesce(g ->> 'visit', '')), 80), '');
    g_anon := nullif(left(btrim(coalesce(g ->> 'anon', '')), 120), '');
    if g_cc is not null or g_city is not null or g_clock is not null then
      if v_id is not null then
        select j.near, j.src, j.km into g_near, g_src, g_km
          from public.claim_geo_judge(v_id, g_cc, g_city, g_lat, g_lng, g_clock) j;
        if g_visit is not null then
          insert into public.claim_visit_geo
            (visit, anon_id, venue_id, cc, country, city, km, clock_cc, near, src, dc)
          values (g_visit, g_anon, v_id, g_cc, g_country, g_city, g_km, g_clock,
                  g_near, g_src, g_dc)
          on conflict (visit) do nothing;
        end if;
      end if;
      place := public.claim_geo_words(g_near, g_src, g_city, g_country, g_cc, g_clock, g_dc);
      -- (a VPN's or a data centre's place does not go in the title)
      if not (g_dc and coalesce(g_src, 'ip') = 'ip') then
        title := case g_near when 'near' then 'Claim page opened, from nearby'
                             when 'country' then 'Claim page opened, same country'
                             when 'far' then 'Claim page opened, from abroad'
                             else title end;
      end if;
    end if;
  exception when others then
    place := ''; title := 'Claim page opened';
  end;

  what := case when v_name is not null
               then ' for ' || v_name || coalesce(' in ' || nullif(v_city, ''), '')
               when seed is not null then ' for "' || seed || '"'
               else '' end;
  whence := case when frm is not null then 'from nomadwise.io' || frm
                 when ref is not null then 'from ' ||
                      regexp_replace(ref, '^https?://(www[.])?', '')
                 else 'direct, no referrer' end;

  perform public.notify_phone(
    title,
    'Someone opened the claim page' || what || ', ' || whence || '.'
      || case when coalesce(place, '') <> '' then ' ' || place else '' end,
    'eyes');
end $$;
revoke all on function public.claim_opened(text, text, text, text, jsonb) from public;
grant execute on function public.claim_opened(text, text, text, text, jsonb) to anon, authenticated;

-- The visits of the last days, from the analytics, so the looks
-- already in Outreach say where they were from (connection only; the
-- clock is noted from today). Ours are left out.
insert into public.claim_visit_geo (visit, anon_id, venue_id, at, cc, country, city, km, near, src)
select s.visit,
       (select e.anon_id from public.app_events e
         where e.props ->> 'visit' = s.visit and left(e.name, 6) = 'claim_' limit 1),
       v.id, s.at::timestamptz, s.cc, s.country, nullif(s.city, ''), j.km, j.near, j.src
  from (values
    ('muxreu7soof',  'biliq-seminyak',                                 '2026-10-07 07:01+00', 'SG', 'Singapore', 'Singapore'),
    ('muwfdyn87u6',  'thailand-bangkok-library-cafe',                  '2026-10-06 08:37+00', 'SG', 'Singapore', 'Singapore'),
    ('muw0034910eg', 'yellow-coworking-space',                         '2026-10-06 01:26+00', 'TH', 'Thailand',  'Chiang Mai'),
    ('muvtme7iefa',  'pura-vida-seseh',                                '2026-10-05 22:28+00', 'SG', 'Singapore', 'Singapore'),
    ('muugv0eq11hh', 'portugal-lisbon-lisbon-cowork',                  '2026-10-04 23:43+00', 'PT', 'Portugal',  'Lisbon'),
    ('mumbbe9819wh', 'sri-lanka-kandy-kopi-club',                      '2026-09-29 06:45+00', 'LK', 'Sri Lanka', 'Colombo'),
    ('mulw0xfj1b2',  'portugal-ericeira-kelp-coworking-space-ericeira', '2026-09-28 23:37+00', 'PT', 'Portugal',  'Lisbon'),
    ('mulfsykaghl',  'portugal-ericeira-kelp-coworking-space-ericeira', '2026-09-28 16:03+00', 'PT', 'Portugal',  'Lisbon'),
    ('mulfqk5ex4t',  'portugal-ericeira-the-capsule',                  '2026-09-28 16:01+00', 'PT', 'Portugal',  'Ericeira'),
    ('mulfm00417u6', 'portugal-ericeira-the-capsule',                  '2026-09-28 15:58+00', 'PT', 'Portugal',  'Ericeira'),
    ('muleap3ksv7',  'portugal-ericeira-kelp-coworking-space-ericeira', '2026-09-28 15:21+00', 'PT', 'Portugal',  'Ericeira')
  ) as s(visit, slug, at, cc, country, city)
  join public.venues v on v.webflow_slug = s.slug
 cross join lateral public.claim_geo_judge(v.id, s.cc, s.city, null, null, null) j
on conflict (visit) do nothing;

-- ------------------------------------------------ the list
-- As migration 153, with the account on each row and two more steps.
create or replace function public.admin_outreach_list(
  p_stage text default null, p_q text default null, p_limit integer default 200,
  p_group text default null, p_step text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  q  text := lower(trim(coalesce(p_q, '')));
  st text := coalesce(nullif(btrim(p_step), ''), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    with act as materialized (
      select y.*, (y.claimed_self or y.accessed) as mine
        from (select a.*,
                     (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                     (a.signed_in_at is not null or a.opens > 0
                      or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                from public.outreach_owner_activity() a) y
    ),
    -- somebody opened the claim page and it is still to follow up
    look as materialized (
      select k.*, public.claim_look_geo(k.venue_id, k.last_at) as geo
        from public.claim_look_lines() k
    ),
    -- an account on the map that is plainly this space's
    signup as materialized (
      select * from public.signup_lines()
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_first, x.sort_rank, x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at, c.is_test,
               (c.email is null) as no_email,
               -- the look's own list: the latest look first, with or
               -- without an address
               (case when st in ('claim_looked', 'form_begun', 'signed_up') then false
                     else c.email is null end) as sort_first,
               -- a look from the space's own area first, then its
               -- country, then not known, then another country
               (case when st in ('claim_looked', 'form_begun')
                     then case l.geo ->> 'near' when 'near' then 0 when 'country' then 1
                                                when 'far' then 3 else 2 end
                     else 0 end) as sort_rank,
               (case when st in ('claim_looked', 'form_begun') then l.last_at
                     when st = 'signed_up' then su.signed_up_at
                     else greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) end) as sort_at,
               v.google_place_id as place_id,
               case when l.contact_id is not null then jsonb_build_object(
                 'last_at', l.last_at, 'opens', l.opens, 'visitors', l.visitors,
                 'furthest', l.furthest, 'secs', l.secs, 'from', l.from_path,
                 'referrer', l.referrer, 'device', l.device,
                 'form_email', l.form_email, 'form_name', l.form_name,
                 'geo', l.geo) end as claim_look,
               case when su.contact_id is not null then jsonb_build_object(
                 'email', su.email, 'name', su.display_name,
                 'at', su.signed_up_at, 'how', su.how) end as signup,
               v.name as venue_name, v.city as venue_city, v.country as venue_country,
               v.webflow_slug, (v.webflow_cms_id is not null) as on_site,
               v.listing_tier, v.listing_owner_email,
               (select m.body from public.outreach_messages m
                 where m.contact_id = c.id and m.direction = 'in'
                 order by m.at desc limit 1) as last_in,
               (select count(*) from public.outreach_messages m where m.contact_id = c.id) as message_count,
               case when a.venue_id is not null then jsonb_build_object(
                 'signed_in_at', a.signed_in_at, 'accessed', a.accessed,
                 'opens', a.opens, 'open_days', a.open_days, 'last_open', a.last_open,
                 'edits', a.edits, 'submitted', a.submitted, 'answers', a.answers,
                 'ideas', a.ideas, 'billing', a.billing, 'did', a.did,
                 'last_did', a.last_did, 'looked', a.looked, 'checkout', a.checkout,
                 -- false: we set this space up and they have not claimed it
                 'mine', a.mine) end as owner
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
          left join act a on a.venue_id = c.venue_id and c.stage in ('claimed', 'verified')
          left join look l on l.contact_id = c.id
          left join signup su on su.contact_id = c.id
         -- a line marked as a test shows under "Tests" and nowhere else
         where (case when st = '' and coalesce(p_stage, '') = 'tests'
                     then c.is_test else not c.is_test end)
           -- the chips: "Set up by us" has its own, and those lines are
           -- not under Claimed or Verified
           and (st <> '' or coalesce(p_stage, '') in ('', 'tests')
                or (p_stage = 'ours' and coalesce(not a.mine, false))
                or (c.stage = p_stage
                    and not (p_stage in ('claimed', 'verified') and coalesce(not a.mine, false))))
           and (st <> '' or coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
           and (q = '' or lower(coalesce(c.space_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.email, '')) like '%' || q || '%'
                       or lower(coalesce(c.person_name, '')) like '%' || q || '%'
                       or lower(coalesce(c.city, '')) like '%' || q || '%'
                       or lower(coalesce(c.country, '')) like '%' || q || '%'
                       or lower(coalesce(v.name, '')) like '%' || q || '%')
           and (st = '' or case st
                  when 'no_email'    then c.stage = 'new' and c.email is null
                  when 'ready'       then c.stage = 'new' and c.email is not null
                  when 'waiting'     then c.stage = 'contacted'
                  when 'follow_up'   then public.outreach_follow_up_due(
                                            c.stage, c.follow_up_on, c.last_out_at)
                  when 'replied'     then c.stage = 'replied'
                  when 'stepped_off' then c.stage in ('not_now', 'declined', 'unsubscribed', 'bounced')
                  when 'claim_looked' then l.contact_id is not null
                  when 'form_begun'   then l.contact_id is not null and l.form_email is not null
                  when 'signed_up'    then su.contact_id is not null
                  when 'claimed'     then coalesce(a.mine, false)
                  when 'not_opened'  then coalesce(a.mine and not a.accessed, false)
                  when 'ours'        then coalesce(not a.mine, false)
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.mine and a.looked, false)
                  when 'verified'    then coalesce(a.mine and a.tier = 'verified', false)
                  else false end)
         order by sort_first, sort_rank, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

-- ------------------------------------------------ the numbers for the picture
-- As migration 153, with the two new numbers.
create or replace function public.admin_outreach_path()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  reach  jsonb;
  own    jsonb;
  paying integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  select jsonb_build_object(
           'no_email',    count(*) filter (where c.stage = 'new' and c.email is null),
           'ready',       count(*) filter (where c.stage = 'new' and c.email is not null),
           'waiting',     count(*) filter (where c.stage = 'contacted'),
           'follow_up',   count(*) filter (where public.outreach_follow_up_due(
                                                   c.stage, c.follow_up_on, c.last_out_at)),
           'replied',     count(*) filter (where c.stage = 'replied'),
           'stepped_off', count(*) filter (where c.stage in
                                             ('not_now', 'declined', 'unsubscribed', 'bounced')))
    into reach
    from public.space_contacts c
   where not c.is_test;

  -- Spaces whose claim page was opened and that are still to follow
  -- up (migration 153). Counted by space.
  begin
    reach := reach || (
      select jsonb_build_object(
               'claim_looked', count(distinct l.venue_id),
               -- of those, the ones seen from the space's own area or country
               'claim_looked_local', count(distinct l.venue_id) filter (
                 where public.claim_look_geo(l.venue_id, l.last_at) ->> 'near'
                       in ('near', 'country')),
               -- of those, the ones whose claim form was begun and left
               'form_begun', count(distinct l.venue_id) filter (where l.form_email is not null))
        from public.claim_look_lines() l);
  exception when others then
    null;
  end;
  -- Accounts on the map that are plainly a listed space's (migration
  -- 154), still to follow up. Counted by space.
  begin
    reach := reach || jsonb_build_object('signed_up',
      (select count(*) from public.signup_lines()));
  exception when others then
    null;
  end;

  -- "mine": they claimed it themselves, or have been in the Owner
  -- account. The rest we set up (Verified by us, or an owner put on by
  -- hand) and they have not claimed: "ours", the ones to invite.
  select jsonb_build_object(
           'claimed',     count(*) filter (where x.mine),
           'not_opened',  count(*) filter (where x.mine and not x.accessed),
           'opened',      count(*) filter (where x.accessed),
           'opened_only', count(*) filter (where x.accessed and x.did = 0),
           'used',        count(*) filter (where x.did > 0),
           'looked',      count(*) filter (where x.mine and x.looked),
           'verified',    count(*) filter (where x.mine and x.tier = 'verified'),
           'ours',        count(*) filter (where not x.mine),
           'ours_verified', count(*) filter (where not x.mine and x.tier = 'verified'))
    into own
    from (select y.*, (y.claimed_self or y.accessed) as mine
            from (select a.*,
                         (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                         (a.signed_in_at is not null or a.opens > 0
                          or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
                    from public.outreach_owner_activity() a
                   where not a.test) y) x;

  -- Paying, as the Money card counts it.
  begin
    paying := (public.admin_money() ->> 'paying')::integer;
  exception when others then
    paying := null;
  end;

  return jsonb_build_object(
    'reach', reach,
    'owners', own,
    'paying', paying,
    -- lines marked as tests, left out of every number above
    'tests', (select count(*) from public.space_contacts c where c.is_test),
    'visits_since', (select s.value #>> '{}' from public.sync_settings s
                      where s.key = 'owner_visits_since'));
end $$;
revoke all on function public.admin_outreach_path() from public, anon;
grant execute on function public.admin_outreach_path() to authenticated;

-- ------------------------------------------------ Next up, and the number beside Outreach
-- As migration 153, with the latest such account.
create or replace function public.admin_next_up()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  out   jsonb := '{}'::jsonb;
  part  jsonb;
  look_ids uuid[];
  sign_ids uuid[];
  pages jsonb;
  cand  jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;

  -- Text upgrades waiting for a Go: how many, on how many pages, and
  -- the most promising page among them.
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'pages', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.name))[1],
             'waiting', (array_agg(t.waiting order by t.impact desc, t.name))[1])
      into part
      from (select v.id, v.name, count(*) as waiting,
                   public.upgrade_impact(v, 'description') as impact
              from public.page_upgrades u
              join public.venues v on v.id = u.venue_id
             where u.kind <> 'photos' and u.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('drafts', part);
  exception when others then
    null;
  end;

  -- Price changes waiting for a Go: the first space as Price check
  -- lists them (by name).
  begin
    select jsonb_build_object(
             'n', coalesce(sum(t.waiting), 0),
             'spaces', count(*),
             'venue_id', (array_agg(t.id order by t.name, t.id))[1],
             'name', (array_agg(t.name order by t.name, t.id))[1],
             'waiting', (array_agg(t.waiting order by t.name, t.id))[1])
      into part
      from (select v.id, v.name, count(*) as waiting
              from public.product_changes c
              join public.venues v on v.id = c.venue_id
             where c.status in ('proposed', 'failed')
             group by v.id) t;
    out := out || jsonb_build_object('prices', part);
  exception when others then
    null;
  end;

  -- Pages short of photos, as "Add photos" lists them, without the
  -- ones whose new photos are already on their way.
  begin
    select jsonb_build_object(
             'n', count(*),
             'venue_id', (array_agg(t.id order by t.impact desc, t.photos, t.name))[1],
             'name', (array_agg(t.name order by t.impact desc, t.photos, t.name))[1],
             'photos', (array_agg(t.photos order by t.impact desc, t.photos, t.name))[1])
      into part
      from (select v.id, v.name, (f.facts ->> 'photos')::int as photos,
                   public.upgrade_impact(v, 'photos') as impact
              from public.venues v
              join public.venue_page_facts f on f.venue_id = v.id
             where public.upgrade_page_is_live(v)
               and (f.facts ->> 'photos') is not null
               and (f.facts ->> 'photos')::int < 5
               and not public.upgrade_owner_photos(v)
               and not exists (select 1 from public.page_upgrades u
                                where u.venue_id = v.id and u.kind = 'photos'
                                  and u.status in ('proposed', 'approved',
                                                   'failed', 'undo_requested'))) t;
    out := out || jsonb_build_object('photos', part);
  exception when others then
    null;
  end;

  -- The first page of "Choose a page" not dealt with yet (migration
  -- 142), and how many such pages the list holds (it shows 300).
  begin
    pages := public.admin_upgrades_pages(null, null, 300);
    select jsonb_build_object(
             'n', count(*),
             'more', jsonb_array_length(pages) >= 300,
             'venue_id', (array_agg(x ->> 'venue_id' order by ord))[1],
             'name', (array_agg(x ->> 'name' order by ord))[1],
             'reason', (array_agg(x ->> 'reason' order by ord))[1])
      into part
      from jsonb_array_elements(pages) with ordinality t(x, ord)
     where (x ->> 'section')::int = 1;
    out := out || jsonb_build_object('page', part);
  exception when others then
    null;
  end;

  -- The best bet on the Candidates list, and how many wait.
  begin
    cand := public.admin_candidates(null, 1, 0, 'best');
    out := out || jsonb_build_object('candidate', jsonb_build_object(
      'n', coalesce((cand ->> 'total')::int, 0),
      'place', cand -> 'rows' -> 0 ->> 'google_place_id',
      'name', cand -> 'rows' -> 0 ->> 'name',
      'area', cand -> 'rows' -> 0 ->> 'area',
      'coworking', coalesce((cand -> 'rows' -> 0 ->> 'coworking')::boolean, false),
      'mentions', coalesce((cand -> 'rows' -> 0 ->> 'mentions')::int, 0),
      'searches', (cand -> 'rows' -> 0 ->> 'searches')::int));
  exception when others then
    null;
  end;

  -- A space whose claim page was opened in the last two weeks and
  -- that is still to follow up (migration 153): how many, and the
  -- latest one.
  begin
    -- (the one named is the nearest to its space, then the latest)
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(t.name order by t.rk, t.last_at desc))[1],
             'at', max(t.last_at),
             'opens', (array_agg(t.opens order by t.rk, t.last_at desc))[1],
             'local', count(*) filter (where t.rk <= 1),
             'where', (array_agg(t.geo ->> 'words' order by t.rk, t.last_at desc))[1]),
           array_agg(t.venue_id)
      into part, look_ids
      from (select z.*,
                   case z.geo ->> 'near' when 'near' then 0 when 'country' then 1
                                         when 'far' then 3 else 2 end as rk
              from (select l.venue_id, max(v.name) as name, max(l.last_at) as last_at,
                           max(l.opens) as opens,
                           public.claim_look_geo(l.venue_id, max(l.last_at)) as geo
                      from public.claim_look_lines() l
                      join public.venues v on v.id = l.venue_id
                     where l.last_at > now() - interval '14 days'
                     group by l.venue_id) z) t;
    out := out || jsonb_build_object('claim_look', part);
  exception when others then
    null;
  end;

  -- An account made on the map in the last two weeks that is plainly a
  -- listed space's, still to follow up (migration 154).
  begin
    select jsonb_build_object(
             'n', count(*),
             'name', (array_agg(v.name order by s.signed_up_at desc))[1],
             'at', max(s.signed_up_at)),
           array_agg(s.venue_id)
      into part, sign_ids
      from public.signup_lines() s
      join public.venues v on v.id = s.venue_id
     where s.signed_up_at > now() - interval '14 days';
    out := out || jsonb_build_object('signup', part);
  exception when others then
    null;
  end;

  -- The numbers beside the menu's other tools (migration 146): what
  -- is open in each. Each in its own block: a tool whose tables are
  -- not there says nothing, the others still do.
  declare
    n_outreach integer;
    n_review   integer;
    n_feedback integer;
  begin
    begin
      -- Outreach: a space answered and waits for a reply, or a
      -- follow-up you set has come due and nothing has been sent
      -- since that day (the date stays on the contact after sending).
      select count(*) into n_outreach
        from public.space_contacts c
       where not c.is_test
         and (c.stage = 'replied'
          or (c.follow_up_on is not null and c.follow_up_on <= current_date
              and (c.last_out_at is null
                   or c.last_out_at::date < c.follow_up_on)
              and c.stage not in ('claimed', 'verified', 'declined',
                                  'unsubscribed', 'bounced')));
      -- and the spaces that looked at claiming, or made an account,
      -- in the last two weeks (a space with both counts once)
      n_outreach := n_outreach + (
        select count(distinct x.id)
          from unnest(coalesce(look_ids, '{}'::uuid[]) || coalesce(sign_ids, '{}'::uuid[])) as x(id));
    exception when others then
      n_outreach := null;
    end;
    begin
      -- Review submissions: reports waiting to be checked, and photos
      -- waiting for a yes or no.
      select count(*) filter (where s.status = 'pending')
           + count(*) filter (where s.photo_path is not null
                                and s.photo_status = 'pending')
        into n_review
        from public.submissions s;
    exception when others then
      n_review := null;
    end;
    begin
      -- Feedback inbox: messages not marked done.
      select count(*) into n_feedback
        from public.feedback f where f.status = 'new';
    exception when others then
      n_feedback := null;
    end;
    out := out || jsonb_build_object('menu', jsonb_strip_nulls(jsonb_build_object(
      'outreach', n_outreach, 'review', n_review, 'feedback', n_feedback)));
  end;

  return out;
end $$;
revoke all on function public.admin_next_up() from public, anon;
grant execute on function public.admin_next_up() to authenticated;

-- ------------------------------------------------ "Done for now" on an account
create or replace function public.admin_outreach_signup_done(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  vid uuid;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select c.venue_id into vid from public.space_contacts c where c.id = p_id;
  update public.space_contacts c
     set signup_done_at = now()
   where c.id = p_id or (vid is not null and c.venue_id = vid);
end $$;
revoke all on function public.admin_outreach_signup_done(uuid) from public, anon;
grant execute on function public.admin_outreach_signup_done(uuid) to authenticated;

-- ------------------------------------------------ the template
-- The account may be an employee's or a regular's, and the email may
-- go to the space's general inbox and not to the account's own
-- address, so the words leave room for both. A first draft: change it in Outreach, Templates.
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('signed_up', 'Follow-up: they made an account on the map',
 '{space} on Nomadwise',
 'Hi {first_name},

An account was made on Nomad Maps recently that looks connected to {space}, so I wanted to say hello. {space} has a page on nomadwise.io: {page_link}

If you run {space}, the page is yours to take over. Claiming it is free, and you get an Owner account where you can correct the facts and add your own photos, description and prices: {claim_link}

If I have this wrong, no problem at all.

{signoff}', 'outbound', 62)
on conflict (key) do nothing;

-- ------------------------------------------------ lines for the matches, kept up
do $$
begin
  perform public.signup_match_sync();
exception when others then
  raise warning 'signup_match_sync: %', sqlerrm;
end $$;

do $$
begin
  perform cron.unschedule('signup-match-sync');
exception when others then null;
end $$;
select cron.schedule('signup-match-sync', '12,42 * * * *',
  'select public.signup_match_sync()');

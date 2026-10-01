-- ============================================================
-- Migration 115: Verified priced by country group, monthly or yearly,
-- in EUR, GBP, USD or AUD (Leonie's green light, 1 Oct 2026).
-- (Applied automatically by the build. The Stripe prices are created
--  by hand once, see docs/BILLING.md, "Prices by region".)
--
-- The framework (Notion, "Owner features and pricing ideas"):
--   A. High cost    15 EUR a month / 149 a year
--   B. Europe       10 / 99   (the anchor, today's price)
--   C. Middle        6 / 59   (Indonesia here, Leonie)
--   D. Lower cost    4 / 39
-- Yearly is about ten months. The price follows the space's address.
-- Every country has a group and a default currency: GBP for the UK
-- (and only GBP there), EUR for Europe, AUD for Australia, USD for the
-- rest, with a toggle to the other currencies. Each currency has its
-- own clean price set in Stripe (no live exchange rate), so the page
-- shows exactly what Stripe charges.
--
-- How it fits together:
--   pricing_groups     the four groups, EUR prices, the Stripe price
--                      ids (one monthly, one yearly, each carrying the
--                      other currencies as Stripe currency options)
--                      and a cache of the amounts Stripe holds, which
--                      the hourly Stripe sync refreshes
--   pricing_countries  every country: group, default currency
--   pricing_for(country)   what the claim form and Owner account show
--   start_checkout(...)    one Stripe Checkout session for a claim, in
--                          the chosen period and currency
-- Until the Stripe price ids are in, pricing_for says ready=false and
-- the app keeps today's payment link (99 EUR a year), so nothing
-- changes by itself. Founders edit groups and countries from the
-- control centre (Pricing page).
-- ============================================================

create table if not exists public.pricing_groups (
  code                 text primary key check (code in ('A', 'B', 'C', 'D')),
  name                 text not null,
  sort                 integer not null default 0,
  monthly_eur          numeric not null check (monthly_eur > 0),
  yearly_eur           numeric not null check (yearly_eur > 0),
  stripe_price_monthly text,
  stripe_price_yearly  text,
  -- {"monthly": {"EUR": 1000, "GBP": 900}, "yearly": {...}} in minor
  -- units, exactly as Stripe holds them (refreshed by stripe_sync.py).
  amounts              jsonb not null default '{}'::jsonb,
  amounts_at           timestamptz,
  updated_at           timestamptz not null default now()
);
insert into public.pricing_groups (code, name, sort, monthly_eur, yearly_eur) values
  ('A', 'High cost', 1, 15, 149),
  ('B', 'Europe', 2, 10, 99),
  ('C', 'Middle', 3, 6, 59),
  ('D', 'Lower cost', 4, 4, 39)
on conflict (code) do nothing;

create table if not exists public.pricing_countries (
  iso              text primary key,
  name             text not null,
  group_code       text not null references public.pricing_groups(code),
  currency         text not null default 'USD' check (currency in ('EUR', 'GBP', 'USD', 'AUD')),
  currency_locked  boolean not null default false,
  note             text,
  updated_at       timestamptz not null default now()
);
insert into public.pricing_countries (iso, name, group_code, currency, currency_locked) values
  ('AF', 'Afghanistan', 'D', 'USD', false),
  ('AL', 'Albania', 'C', 'EUR', false),
  ('DZ', 'Algeria', 'D', 'USD', false),
  ('AS', 'American Samoa', 'A', 'USD', false),
  ('AD', 'Andorra', 'B', 'EUR', false),
  ('AO', 'Angola', 'D', 'USD', false),
  ('AI', 'Anguilla', 'A', 'USD', false),
  ('AG', 'Antigua and Barbuda', 'C', 'USD', false),
  ('AR', 'Argentina', 'C', 'USD', false),
  ('AM', 'Armenia', 'C', 'EUR', false),
  ('AW', 'Aruba', 'A', 'USD', false),
  ('AU', 'Australia', 'A', 'AUD', false),
  ('AT', 'Austria', 'B', 'EUR', false),
  ('AZ', 'Azerbaijan', 'C', 'EUR', false),
  ('BS', 'Bahamas', 'A', 'USD', false),
  ('BH', 'Bahrain', 'A', 'USD', false),
  ('BD', 'Bangladesh', 'D', 'USD', false),
  ('BB', 'Barbados', 'A', 'USD', false),
  ('BY', 'Belarus', 'C', 'EUR', false),
  ('BE', 'Belgium', 'B', 'EUR', false),
  ('BZ', 'Belize', 'C', 'USD', false),
  ('BJ', 'Benin', 'D', 'USD', false),
  ('BM', 'Bermuda', 'A', 'USD', false),
  ('BT', 'Bhutan', 'D', 'USD', false),
  ('BO', 'Bolivia', 'D', 'USD', false),
  ('BA', 'Bosnia and Herzegovina', 'C', 'EUR', false),
  ('BW', 'Botswana', 'C', 'USD', false),
  ('BR', 'Brazil', 'C', 'USD', false),
  ('IO', 'British Indian Ocean Territory', 'C', 'USD', false),
  ('VG', 'British Virgin Islands', 'A', 'USD', false),
  ('BN', 'Brunei', 'B', 'USD', false),
  ('BG', 'Bulgaria', 'B', 'EUR', false),
  ('BF', 'Burkina Faso', 'D', 'USD', false),
  ('BI', 'Burundi', 'D', 'USD', false),
  ('KH', 'Cambodia', 'D', 'USD', false),
  ('CM', 'Cameroon', 'D', 'USD', false),
  ('CA', 'Canada', 'A', 'USD', false),
  ('CV', 'Cape Verde', 'C', 'USD', false),
  ('BQ', 'Caribbean Netherlands', 'D', 'USD', false),
  ('KY', 'Cayman Islands', 'A', 'USD', false),
  ('CF', 'Central African Republic', 'D', 'USD', false),
  ('TD', 'Chad', 'D', 'USD', false),
  ('CL', 'Chile', 'C', 'USD', false),
  ('CN', 'China', 'C', 'USD', false),
  ('CX', 'Christmas Island', 'C', 'USD', false),
  ('CC', 'Cocos (Keeling) Islands', 'C', 'USD', false),
  ('CO', 'Colombia', 'C', 'USD', false),
  ('KM', 'Comoros', 'D', 'USD', false),
  ('CG', 'Congo', 'D', 'USD', false),
  ('CK', 'Cook Islands', 'C', 'USD', false),
  ('CR', 'Costa Rica', 'C', 'USD', false),
  ('HR', 'Croatia', 'B', 'EUR', false),
  ('CU', 'Cuba', 'C', 'USD', false),
  ('CW', 'Curaçao', 'A', 'USD', false),
  ('CY', 'Cyprus', 'B', 'EUR', false),
  ('CZ', 'Czechia', 'B', 'EUR', false),
  ('CD', 'DR Congo', 'D', 'USD', false),
  ('DK', 'Denmark', 'A', 'EUR', false),
  ('DJ', 'Djibouti', 'D', 'USD', false),
  ('DM', 'Dominica', 'C', 'USD', false),
  ('DO', 'Dominican Republic', 'C', 'USD', false),
  ('EC', 'Ecuador', 'C', 'USD', false),
  ('EG', 'Egypt', 'D', 'USD', false),
  ('SV', 'El Salvador', 'D', 'USD', false),
  ('GQ', 'Equatorial Guinea', 'C', 'USD', false),
  ('ER', 'Eritrea', 'D', 'USD', false),
  ('EE', 'Estonia', 'B', 'EUR', false),
  ('SZ', 'Eswatini', 'D', 'USD', false),
  ('ET', 'Ethiopia', 'D', 'USD', false),
  ('FK', 'Falkland Islands', 'A', 'USD', false),
  ('FO', 'Faroe Islands', 'A', 'EUR', false),
  ('FJ', 'Fiji', 'C', 'USD', false),
  ('FI', 'Finland', 'A', 'EUR', false),
  ('FR', 'France', 'B', 'EUR', false),
  ('GF', 'French Guiana', 'A', 'USD', false),
  ('PF', 'French Polynesia', 'A', 'USD', false),
  ('GA', 'Gabon', 'C', 'USD', false),
  ('GM', 'Gambia', 'D', 'USD', false),
  ('GE', 'Georgia', 'C', 'EUR', false),
  ('DE', 'Germany', 'B', 'EUR', false),
  ('GH', 'Ghana', 'D', 'USD', false),
  ('GI', 'Gibraltar', 'A', 'EUR', false),
  ('GR', 'Greece', 'B', 'EUR', false),
  ('GL', 'Greenland', 'A', 'EUR', false),
  ('GD', 'Grenada', 'C', 'USD', false),
  ('GP', 'Guadeloupe', 'A', 'USD', false),
  ('GU', 'Guam', 'A', 'USD', false),
  ('GT', 'Guatemala', 'C', 'USD', false),
  ('GG', 'Guernsey', 'A', 'GBP', true),
  ('GN', 'Guinea', 'D', 'USD', false),
  ('GW', 'Guinea-Bissau', 'D', 'USD', false),
  ('GY', 'Guyana', 'C', 'USD', false),
  ('HT', 'Haiti', 'D', 'USD', false),
  ('HN', 'Honduras', 'D', 'USD', false),
  ('HK', 'Hong Kong', 'A', 'USD', false),
  ('HU', 'Hungary', 'B', 'EUR', false),
  ('IS', 'Iceland', 'A', 'EUR', false),
  ('IN', 'India', 'D', 'USD', false),
  ('ID', 'Indonesia', 'C', 'USD', false),
  ('IR', 'Iran', 'D', 'USD', false),
  ('IQ', 'Iraq', 'D', 'USD', false),
  ('IE', 'Ireland', 'A', 'EUR', false),
  ('IM', 'Isle of Man', 'A', 'GBP', true),
  ('IL', 'Israel', 'A', 'USD', false),
  ('IT', 'Italy', 'B', 'EUR', false),
  ('JM', 'Jamaica', 'C', 'USD', false),
  ('JP', 'Japan', 'A', 'USD', false),
  ('JE', 'Jersey', 'A', 'GBP', true),
  ('JO', 'Jordan', 'C', 'USD', false),
  ('KZ', 'Kazakhstan', 'C', 'USD', false),
  ('KE', 'Kenya', 'D', 'USD', false),
  ('KI', 'Kiribati', 'C', 'USD', false),
  ('KW', 'Kuwait', 'A', 'USD', false),
  ('KG', 'Kyrgyzstan', 'D', 'USD', false),
  ('LA', 'Laos', 'D', 'USD', false),
  ('LV', 'Latvia', 'B', 'EUR', false),
  ('LB', 'Lebanon', 'C', 'USD', false),
  ('LS', 'Lesotho', 'D', 'USD', false),
  ('LR', 'Liberia', 'D', 'USD', false),
  ('LY', 'Libya', 'D', 'USD', false),
  ('LI', 'Liechtenstein', 'A', 'EUR', false),
  ('LT', 'Lithuania', 'B', 'EUR', false),
  ('LU', 'Luxembourg', 'B', 'EUR', false),
  ('MO', 'Macao', 'A', 'USD', false),
  ('MG', 'Madagascar', 'D', 'USD', false),
  ('MW', 'Malawi', 'D', 'USD', false),
  ('MY', 'Malaysia', 'C', 'USD', false),
  ('MV', 'Maldives', 'C', 'USD', false),
  ('ML', 'Mali', 'D', 'USD', false),
  ('MT', 'Malta', 'B', 'EUR', false),
  ('MH', 'Marshall Islands', 'C', 'USD', false),
  ('MQ', 'Martinique', 'A', 'USD', false),
  ('MR', 'Mauritania', 'D', 'USD', false),
  ('MU', 'Mauritius', 'C', 'USD', false),
  ('YT', 'Mayotte', 'A', 'USD', false),
  ('MX', 'Mexico', 'C', 'USD', false),
  ('FM', 'Micronesia', 'C', 'USD', false),
  ('MD', 'Moldova', 'D', 'EUR', false),
  ('MC', 'Monaco', 'B', 'EUR', false),
  ('MN', 'Mongolia', 'D', 'USD', false),
  ('ME', 'Montenegro', 'C', 'EUR', false),
  ('MS', 'Montserrat', 'C', 'USD', false),
  ('MA', 'Morocco', 'C', 'USD', false),
  ('MZ', 'Mozambique', 'D', 'USD', false),
  ('MM', 'Myanmar', 'D', 'USD', false),
  ('NA', 'Namibia', 'C', 'USD', false),
  ('NR', 'Nauru', 'C', 'USD', false),
  ('NP', 'Nepal', 'D', 'USD', false),
  ('NL', 'Netherlands', 'B', 'EUR', false),
  ('NC', 'New Caledonia', 'A', 'USD', false),
  ('NZ', 'New Zealand', 'A', 'USD', false),
  ('NI', 'Nicaragua', 'D', 'USD', false),
  ('NE', 'Niger', 'D', 'USD', false),
  ('NG', 'Nigeria', 'D', 'USD', false),
  ('NU', 'Niue', 'C', 'USD', false),
  ('NF', 'Norfolk Island', 'C', 'USD', false),
  ('KP', 'North Korea', 'D', 'USD', false),
  ('MK', 'North Macedonia', 'C', 'EUR', false),
  ('MP', 'Northern Mariana Islands', 'A', 'USD', false),
  ('NO', 'Norway', 'A', 'EUR', false),
  ('OM', 'Oman', 'B', 'USD', false),
  ('PK', 'Pakistan', 'D', 'USD', false),
  ('PW', 'Palau', 'C', 'USD', false),
  ('PS', 'Palestine', 'D', 'USD', false),
  ('PA', 'Panama', 'C', 'USD', false),
  ('PG', 'Papua New Guinea', 'D', 'USD', false),
  ('PY', 'Paraguay', 'D', 'USD', false),
  ('PE', 'Peru', 'C', 'USD', false),
  ('PH', 'Philippines', 'D', 'USD', false),
  ('PL', 'Poland', 'B', 'EUR', false),
  ('PT', 'Portugal', 'B', 'EUR', false),
  ('PR', 'Puerto Rico', 'A', 'USD', false),
  ('QA', 'Qatar', 'A', 'USD', false),
  ('RO', 'Romania', 'B', 'EUR', false),
  ('RU', 'Russia', 'C', 'EUR', false),
  ('RW', 'Rwanda', 'D', 'USD', false),
  ('RE', 'Réunion', 'A', 'USD', false),
  ('BL', 'Saint Barthelemy', 'A', 'USD', false),
  ('SH', 'Saint Helena', 'C', 'USD', false),
  ('KN', 'Saint Kitts and Nevis', 'C', 'USD', false),
  ('LC', 'Saint Lucia', 'C', 'USD', false),
  ('MF', 'Saint Martin', 'A', 'USD', false),
  ('PM', 'Saint Pierre and Miquelon', 'A', 'USD', false),
  ('VC', 'Saint Vincent and the Grenadines', 'C', 'USD', false),
  ('WS', 'Samoa', 'C', 'USD', false),
  ('SM', 'San Marino', 'B', 'EUR', false),
  ('ST', 'Sao Tome and Principe', 'D', 'USD', false),
  ('SA', 'Saudi Arabia', 'B', 'USD', false),
  ('SN', 'Senegal', 'D', 'USD', false),
  ('RS', 'Serbia', 'C', 'EUR', false),
  ('SC', 'Seychelles', 'C', 'USD', false),
  ('SL', 'Sierra Leone', 'D', 'USD', false),
  ('SG', 'Singapore', 'A', 'USD', false),
  ('SX', 'Sint Maarten', 'A', 'USD', false),
  ('SK', 'Slovakia', 'B', 'EUR', false),
  ('SI', 'Slovenia', 'B', 'EUR', false),
  ('SB', 'Solomon Islands', 'D', 'USD', false),
  ('SO', 'Somalia', 'D', 'USD', false),
  ('ZA', 'South Africa', 'C', 'USD', false),
  ('KR', 'South Korea', 'B', 'USD', false),
  ('SS', 'South Sudan', 'D', 'USD', false),
  ('ES', 'Spain', 'B', 'EUR', false),
  ('LK', 'Sri Lanka', 'D', 'USD', false),
  ('SD', 'Sudan', 'D', 'USD', false),
  ('SR', 'Suriname', 'C', 'USD', false),
  ('SJ', 'Svalbard and Jan Mayen', 'A', 'EUR', false),
  ('SE', 'Sweden', 'A', 'EUR', false),
  ('CH', 'Switzerland', 'A', 'EUR', false),
  ('SY', 'Syria', 'D', 'USD', false),
  ('TW', 'Taiwan', 'B', 'USD', false),
  ('TJ', 'Tajikistan', 'D', 'USD', false),
  ('TZ', 'Tanzania', 'D', 'USD', false),
  ('TH', 'Thailand', 'C', 'USD', false),
  ('TL', 'Timor-Leste', 'D', 'USD', false),
  ('TG', 'Togo', 'D', 'USD', false),
  ('TK', 'Tokelau', 'C', 'USD', false),
  ('TO', 'Tonga', 'C', 'USD', false),
  ('TT', 'Trinidad and Tobago', 'C', 'USD', false),
  ('TN', 'Tunisia', 'D', 'USD', false),
  ('TR', 'Turkey', 'C', 'EUR', false),
  ('TM', 'Turkmenistan', 'D', 'USD', false),
  ('TC', 'Turks and Caicos Islands', 'A', 'USD', false),
  ('TV', 'Tuvalu', 'C', 'USD', false),
  ('VI', 'US Virgin Islands', 'A', 'USD', false),
  ('UG', 'Uganda', 'D', 'USD', false),
  ('UA', 'Ukraine', 'D', 'EUR', false),
  ('AE', 'United Arab Emirates', 'A', 'USD', false),
  ('GB', 'United Kingdom', 'A', 'GBP', true),
  ('US', 'United States', 'A', 'USD', false),
  ('UY', 'Uruguay', 'C', 'USD', false),
  ('UZ', 'Uzbekistan', 'D', 'USD', false),
  ('VU', 'Vanuatu', 'C', 'USD', false),
  ('VA', 'Vatican City', 'B', 'EUR', false),
  ('VE', 'Venezuela', 'D', 'USD', false),
  ('VN', 'Vietnam', 'D', 'USD', false),
  ('WF', 'Wallis and Futuna', 'A', 'USD', false),
  ('EH', 'Western Sahara', 'D', 'USD', false),
  ('YE', 'Yemen', 'D', 'USD', false),
  ('ZM', 'Zambia', 'D', 'USD', false),
  ('ZW', 'Zimbabwe', 'D', 'USD', false),
  ('AX', 'Åland Islands', 'A', 'EUR', false)
,
  ('CI', 'Côte d''Ivoire', 'D', 'USD', false),
  ('XK', 'Kosovo', 'C', 'EUR', false)
on conflict (iso) do nothing;

-- Other spellings a space's country arrives in (Google, Webflow, the
-- claim form). Lower case, no accents.
create table if not exists public.pricing_aliases (
  alias text primary key,
  iso   text not null references public.pricing_countries(iso)
);
insert into public.pricing_aliases (alias, iso) values
  ('uk', 'GB'), ('united kingdom', 'GB'), ('great britain', 'GB'), ('england', 'GB'),
  ('scotland', 'GB'), ('wales', 'GB'), ('northern ireland', 'GB'),
  ('usa', 'US'), ('united states', 'US'), ('united states of america', 'US'), ('u.s.', 'US'),
  ('uae', 'AE'), ('united arab emirates', 'AE'), ('dubai', 'AE'),
  ('viet nam', 'VN'), ('vietnam', 'VN'),
  ('czech republic', 'CZ'), ('czechia', 'CZ'),
  ('the netherlands', 'NL'), ('holland', 'NL'), ('netherlands', 'NL'),
  ('korea', 'KR'), ('south korea', 'KR'), ('republic of korea', 'KR'),
  ('bali', 'ID'), ('indonesia', 'ID'),
  ('turkiye', 'TR'), ('turkey', 'TR'),
  ('myanmar (burma)', 'MM'), ('burma', 'MM'),
  ('hong kong sar', 'HK'), ('hong kong', 'HK'), ('macau', 'MO'), ('macao', 'MO'),
  ('cote d''ivoire', 'CI'), ('ivory coast', 'CI'),
  ('bosnia', 'BA'), ('bosnia & herzegovina', 'BA'),
  ('north macedonia', 'MK'), ('macedonia', 'MK'),
  ('the gambia', 'GM'), ('gambia', 'GM'),
  ('timor-leste', 'TL'), ('east timor', 'TL'),
  ('russia', 'RU'), ('russian federation', 'RU'),
  ('iran', 'IR'), ('syria', 'SY'), ('laos', 'LA'), ('brunei', 'BN'),
  ('cape verde', 'CV'), ('cabo verde', 'CV'),
  ('eswatini', 'SZ'), ('swaziland', 'SZ'),
  ('tanzania', 'TZ'), ('micronesia', 'FM'), ('moldova', 'MD'),
  ('palestine', 'PS'), ('palestinian territories', 'PS'),
  ('taiwan', 'TW'), ('reunion', 'RE'), ('curacao', 'CW'), ('saint barthelemy', 'BL'),
  ('dr congo', 'CD'), ('democratic republic of the congo', 'CD'), ('congo', 'CG'),
  ('kosovo', 'XK'), ('mexico city', 'MX'), ('canary islands', 'ES'), ('madeira', 'PT'),
  ('tenerife', 'ES'), ('mallorca', 'ES'), ('crete', 'GR')
on conflict (alias) do nothing;

alter table public.pricing_groups enable row level security;
alter table public.pricing_countries enable row level security;
alter table public.pricing_aliases enable row level security;
drop policy if exists "pricing groups public" on public.pricing_groups;
create policy "pricing groups public" on public.pricing_groups for select using (true);
drop policy if exists "pricing countries public" on public.pricing_countries;
create policy "pricing countries public" on public.pricing_countries for select using (true);
drop policy if exists "pricing aliases public" on public.pricing_aliases;
create policy "pricing aliases public" on public.pricing_aliases for select using (true);
grant select on public.pricing_groups, public.pricing_countries, public.pricing_aliases
  to anon, authenticated;

-- A space's country, however it is written, to an ISO code; null when
-- nothing matches.
create or replace function public.pricing_country_iso(p_country text)
returns text language plpgsql stable as $$
declare
  n   text;
  hit text;
begin
  n := lower(trim(coalesce(p_country, '')));
  if n = '' then return null; end if;
  n := translate(n, 'áàâäãåéèêëíìîïóòôöõúùûüçñ', 'aaaaaaeeeeiiiiooooouuuucn');
  n := regexp_replace(n, '[^a-z0-9&,'' .()-]', '', 'g');
  if length(n) = 2 then
    select iso into hit from public.pricing_countries where lower(iso) = n;
    if hit is not null then return hit; end if;
  end if;
  select iso into hit from public.pricing_aliases where alias = n;
  if hit is not null then return hit; end if;
  select iso into hit from public.pricing_countries where lower(name) = n;
  if hit is not null then return hit; end if;
  -- "Bali, Indonesia", "Lisbon, Portugal": the last part names the country.
  if position(',' in n) > 0 then
    return public.pricing_country_iso(trim(split_part(n, ',', -1)));
  end if;
  -- A country name inside the text ("Madeira Portugal"), longest first.
  select iso into hit from public.pricing_countries
   where position(lower(name) in n) > 0 and length(name) >= 4
   order by length(name) desc limit 1;
  return hit;
end $$;
grant execute on function public.pricing_country_iso(text) to anon, authenticated, service_role;

-- Minor units for a currency and period from the Stripe cache, falling
-- back to the EUR price in the table for EUR.
create or replace function public.pricing_amount(p_group public.pricing_groups, p_period text, p_currency text)
returns integer language sql immutable as $$
  select coalesce(
    (p_group.amounts -> p_period ->> p_currency)::integer,
    case when p_currency = 'EUR'
         then round(case p_period when 'monthly' then p_group.monthly_eur else p_group.yearly_eur end * 100)::integer end);
$$;

-- What the claim form and the Owner account show for one country.
create or replace function public.pricing_for(p_country text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_iso text := public.pricing_country_iso(p_country);
  c    public.pricing_countries%rowtype;
  g    public.pricing_groups%rowtype;
  curs text[] := '{}';
  cur  text;
  mon  jsonb := '{}'::jsonb;
  yr   jsonb := '{}'::jsonb;
  a_m  integer;
  a_y  integer;
  ready boolean;
begin
  if v_iso is not null then
    select * into c from public.pricing_countries pc where pc.iso = v_iso;
  end if;
  if v_iso is null or c.iso is null then
    -- Unknown country: today's price, in euros, until a founder maps it.
    select * into g from public.pricing_groups where code = 'B';
    c.iso := null; c.name := null; c.group_code := 'B'; c.currency := 'EUR'; c.currency_locked := false;
  else
    select * into g from public.pricing_groups where code = c.group_code;
  end if;

  -- The currencies on offer: the country's own first, then the others
  -- Stripe has amounts for. Locked (the UK) means only its own.
  foreach cur in array (case when c.currency_locked then array[c.currency]
                             else array[c.currency, 'USD', 'EUR', 'GBP'] end) loop
    if cur = any(curs) then continue; end if;
    a_m := public.pricing_amount(g, 'monthly', cur);
    a_y := public.pricing_amount(g, 'yearly', cur);
    if a_m is null or a_y is null then continue; end if;
    curs := curs || cur;
    mon := mon || jsonb_build_object(cur, a_m);
    yr  := yr  || jsonb_build_object(cur, a_y);
  end loop;
  if array_length(curs, 1) is null then
    curs := array['EUR'];
    mon := jsonb_build_object('EUR', public.pricing_amount(g, 'monthly', 'EUR'));
    yr  := jsonb_build_object('EUR', public.pricing_amount(g, 'yearly', 'EUR'));
  end if;

  ready := coalesce(g.stripe_price_monthly, '') <> '' and coalesce(g.stripe_price_yearly, '') <> '';
  return jsonb_build_object(
    'iso', c.iso,
    'country', c.name,
    'group', g.code,
    'group_name', g.name,
    'currency', curs[1],
    'currencies', to_jsonb(curs),
    'locked', coalesce(c.currency_locked, false),
    'monthly', mon,
    'yearly', yr,
    'monthly_eur', g.monthly_eur,
    'yearly_eur', g.yearly_eur,
    'ready', ready,
    'mapped', c.iso is not null);
end $$;
grant execute on function public.pricing_for(text) to anon, authenticated, service_role;

-- "10", "8.50": an amount without needless decimals.
create or replace function public.money_words(p numeric)
returns text language sql immutable as $$
  select case when p = trunc(p) then trunc(p)::text
              else to_char(p, 'FM999990.00') end;
$$;

-- "10 EUR a month or 99 EUR a year", for emails and the offer text.
create or replace function public.verified_price_words(p_country text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  p   jsonb := public.pricing_for(p_country);
  cur text := p->>'currency';
  m   numeric := (p->'monthly'->>cur)::numeric / 100;
  y   numeric := (p->'yearly'->>cur)::numeric / 100;
begin
  -- Until the prices are in Stripe, today's price, as the app charges.
  if not coalesce((p->>'ready')::boolean, false) then
    return '99 EUR a year';
  end if;
  return public.money_words(m) || ' ' || cur || ' a month or '
      || public.money_words(y) || ' ' || cur || ' a year';
end $$;
grant execute on function public.verified_price_words(text) to anon, authenticated, service_role;

-- Form encoding for Stripe (application/x-www-form-urlencoded).
create or replace function public.form_enc(p text)
returns text language plpgsql immutable as $$
declare
  out text := '';
  ch  text;
  i   integer;
begin
  for i in 1..length(coalesce(p, '')) loop
    ch := substr(p, i, 1);
    if ch ~ '^[A-Za-z0-9_.~-]$' then
      out := out || ch;
    else
      out := out || regexp_replace(encode(convert_to(ch, 'UTF8'), 'hex'), '(..)', '%\1', 'g');
    end if;
  end loop;
  return out;
end $$;

-- The claim remembers what was chosen, for the owners funnel.
alter table public.listing_claims
  add column if not exists billing_period   text check (billing_period in ('monthly', 'yearly')),
  add column if not exists billing_currency text;

-- The claim form is public (anon), whose statements stop after 3 s on
-- Supabase; a Stripe round trip can take longer. 15 s for anon, which
-- the map's own calls never approach.
do $$
begin
  execute 'alter role anon set statement_timeout = ''15s''';
exception when others then
  raise notice 'anon statement_timeout not changed: %', sqlerrm;
end $$;

-- One Stripe Checkout session for a claim: the group's price for the
-- period, presented in the chosen currency. Returns {"url": ...}, or
-- {"error": "not_ready"} when the prices are not in Stripe yet (the app
-- then uses today's payment link).
create or replace function public.start_checkout(p_claim uuid, p_period text, p_currency text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.listing_claims%rowtype;
  country text;
  p       jsonb;
  g       public.pricing_groups%rowtype;
  price   text;
  cur     text := upper(coalesce(p_currency, ''));
  slug    text;
  form    text;
  res     jsonb;
begin
  if p_period not in ('monthly', 'yearly') then
    raise exception 'Choose monthly or yearly.';
  end if;
  select * into c from public.listing_claims where id = p_claim;
  if not found then raise exception 'Claim not found.'; end if;
  if c.status <> 'started' then
    raise exception 'This claim has already been completed.';
  end if;

  if c.venue_id is not null then
    select v.country, v.webflow_slug into country, slug
      from public.venues v where v.id = c.venue_id;
  end if;
  country := coalesce(nullif(trim(country), ''), c.space_country);
  p := public.pricing_for(country);
  if not (p->>'ready')::boolean then
    return jsonb_build_object('error', 'not_ready');
  end if;
  if not (p->'currencies') ? cur then
    cur := p->>'currency';
  end if;
  select * into g from public.pricing_groups where code = p->>'group';
  price := case p_period when 'monthly' then g.stripe_price_monthly else g.stripe_price_yearly end;

  form := 'mode=subscription'
       || '&line_items[0][price]=' || public.form_enc(price)
       || '&line_items[0][quantity]=1'
       || '&currency=' || lower(cur)
       || '&client_reference_id=' || c.id::text
       || '&customer_email=' || public.form_enc(c.owner_email)
       || '&allow_promotion_codes=true'
       || '&success_url=' || public.form_enc('https://nomadmaps.io/?claimed=1')
       || '&cancel_url=' || public.form_enc('https://nomadmaps.io/?claim='
                              || coalesce(slug, replace(coalesce(c.space_name, ''), ' ', '%20'))
                              || '&cancelled=1')
       || '&metadata[claim_id]=' || c.id::text
       || '&metadata[group]=' || g.code
       || '&subscription_data[metadata][claim_id]=' || c.id::text
       || '&subscription_data[metadata][venue_id]=' || coalesce(c.venue_id::text, '');
  res := public.stripe_call('POST', 'checkout/sessions', form);
  if res ? 'error' then
    return jsonb_build_object('error', res->>'error');
  end if;
  update public.listing_claims
     set billing_period = p_period, billing_currency = cur
   where id = p_claim;
  return jsonb_build_object('url', res->>'url', 'currency', cur, 'period', p_period);
end $$;
revoke all on function public.start_checkout(uuid, text, text) from public;
grant execute on function public.start_checkout(uuid, text, text) to anon, authenticated;

-- ------------------------------------------------------------- admin
create or replace function public.admin_pricing()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  -- Each distinct country text is matched once, not once per venue.
  drop table if exists pricing_venue_iso;
  create temp table pricing_venue_iso on commit drop as
    select x.country, public.pricing_country_iso(x.country) as iso,
           x.n, x.verified
      from (select v.country, count(*) n,
                   count(*) filter (where v.listing_tier = 'verified') verified
              from public.venues v
             where coalesce(v.website_status, '') <> 'retired'
             group by v.country) x;
  return jsonb_build_object(
    'groups', (select jsonb_agg(to_jsonb(g) || jsonb_build_object(
                 'spaces', coalesce((select sum(x.n) from pricing_venue_iso x
                                       join public.pricing_countries c on c.iso = x.iso
                                      where c.group_code = g.code), 0),
                 'verified', coalesce((select sum(x.verified) from pricing_venue_iso x
                                         join public.pricing_countries c on c.iso = x.iso
                                        where c.group_code = g.code), 0))
               order by g.sort) from public.pricing_groups g),
    'countries', (select jsonb_agg(jsonb_build_object(
                    'iso', c.iso, 'name', c.name, 'group', c.group_code,
                    'currency', c.currency, 'locked', c.currency_locked,
                    'spaces', coalesce((select sum(x.n) from pricing_venue_iso x where x.iso = c.iso), 0))
                  order by c.name) from public.pricing_countries c),
    'unmapped', coalesce((select jsonb_agg(jsonb_build_object('country', x.country, 'spaces', x.n) order by x.n desc)
                  from pricing_venue_iso x
                 where x.iso is null and coalesce(trim(x.country), '') <> ''), '[]'::jsonb),
    'stripe_connected', exists (select 1 from vault.decrypted_secrets
                                 where name = 'stripe_billing_key' and coalesce(decrypted_secret, '') <> ''));
end $$;
revoke all on function public.admin_pricing() from public, anon;
grant execute on function public.admin_pricing() to authenticated;

create or replace function public.admin_set_pricing_group(
  p_code text, p_monthly_eur numeric, p_yearly_eur numeric,
  p_price_monthly text, p_price_yearly text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if p_monthly_eur is null or p_monthly_eur <= 0 or p_yearly_eur is null or p_yearly_eur <= 0 then
    raise exception 'Prices must be above zero.';
  end if;
  if coalesce(trim(p_price_monthly), '') <> '' and p_price_monthly !~ '^price_[A-Za-z0-9]+$' then
    raise exception 'A Stripe price id starts with price_.';
  end if;
  if coalesce(trim(p_price_yearly), '') <> '' and p_price_yearly !~ '^price_[A-Za-z0-9]+$' then
    raise exception 'A Stripe price id starts with price_.';
  end if;
  update public.pricing_groups
     set monthly_eur = p_monthly_eur,
         yearly_eur = p_yearly_eur,
         stripe_price_monthly = nullif(trim(p_price_monthly), ''),
         stripe_price_yearly = nullif(trim(p_price_yearly), ''),
         -- a new price id means the cached amounts belong to the old one
         amounts = case when stripe_price_monthly is distinct from nullif(trim(p_price_monthly), '')
                          or stripe_price_yearly is distinct from nullif(trim(p_price_yearly), '')
                        then '{}'::jsonb else amounts end,
         updated_at = now()
   where code = p_code;
  if not found then raise exception 'Unknown group.'; end if;
  return public.admin_pricing();
end $$;
revoke all on function public.admin_set_pricing_group(text, numeric, numeric, text, text) from public, anon;
grant execute on function public.admin_set_pricing_group(text, numeric, numeric, text, text) to authenticated;

create or replace function public.admin_set_country(p_iso text, p_group text, p_currency text, p_locked boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  update public.pricing_countries
     set group_code = coalesce(p_group, group_code),
         currency = coalesce(p_currency, currency),
         currency_locked = coalesce(p_locked, currency_locked),
         updated_at = now()
   where iso = upper(p_iso);
  if not found then raise exception 'Unknown country.'; end if;
  return public.admin_pricing();
end $$;
revoke all on function public.admin_set_country(text, text, text, boolean) from public, anon;
grant execute on function public.admin_set_country(text, text, text, boolean) to authenticated;

-- A country name we did not know: map it to a country for good.
create or replace function public.admin_add_alias(p_alias text, p_iso text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  insert into public.pricing_aliases (alias, iso)
  values (lower(trim(p_alias)), upper(p_iso))
  on conflict (alias) do update set iso = excluded.iso;
  return public.admin_pricing();
end $$;
revoke all on function public.admin_add_alias(text, text) from public, anon;
grant execute on function public.admin_add_alias(text, text) to authenticated;

-- The Stripe sync writes the cached amounts.
create or replace function public.set_pricing_amounts(p_code text, p_amounts jsonb)
returns void language sql security definer set search_path = public as $$
  update public.pricing_groups
     set amounts = coalesce(p_amounts, '{}'::jsonb), amounts_at = now()
   where code = p_code;
$$;
revoke all on function public.set_pricing_amounts(text, jsonb) from public, anon, authenticated;
grant execute on function public.set_pricing_amounts(text, jsonb) to service_role;


-- ------------------------------------------------- emails say the price
-- The two owner emails that quoted "99 EUR a year" now say the price
-- for the space's country (the rest of each is as in migrations 95
-- and 91).
create or replace function public.claim_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  space   text;
  kind_of text;
  first   text;
  url     text;
  subj    text;
  body    text;
  kind    text;
  v_city  text;
  sig     text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
  owner_line text := E'\n\nYour Owner account: https://nomadmaps.io/owner\n'
                  || 'Sign in with this email address; we send you a link, there is no password.';
  cta_label text;
  cta_url   text;
begin
  if new.owner_email is null or new.owner_email = '' then return new; end if;

  space := coalesce(nullif(new.space_name, ''),
                    (select v.name from public.venues v where v.id = new.venue_id),
                    'your space');
  kind_of := public.space_kind(coalesce(
               (select v.type from public.venues v where v.id = new.venue_id), new.space_type));
  v_city := coalesce(nullif((select v.city from public.venues v where v.id = new.venue_id), ''),
                    nullif(new.space_city, ''), 'your city');
  first := coalesce(nullif(split_part(trim(coalesce(new.owner_name, '')), ' ', 1), ''), 'there');
  url   := public.owner_page_url(new.venue_id);

  -- Free claim just made.
  if tg_op = 'INSERT' and new.status = 'free_pending' then
    kind := 'claim_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You''ve claimed ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks, you''ve claimed your ' || kind_of || ', ' || space || ', on Nomadwise. '
         || 'Before we hand the page over we check you are with the team at ' || space || ' '
         || '(usually one quick message to the business''s own Instagram, WhatsApp or '
         || 'email), and we email you as soon as that is done.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your ' || kind_of || ' is not on our map yet, so it also joins our '
                      || 'publishing queue; we email you the link when the page is live.'
                 else 'Your page: ' || coalesce(url, 'we send the link once it is live.') end
         || E'\n\n'
         || 'Your Owner account is ready to sign in to now. Once that check is done, '
         || 'you can correct the facts and add your own photos, description, prices and '
         || 'opening hours there.'
         || owner_line || sig;

  -- Payment landed, claim waiting for us.
  elsif tg_op = 'UPDATE' and old.status = 'started' and new.status = 'awaiting_approval' then
    kind := 'payment_received';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'Payment received for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks, you''ve claimed your ' || kind_of || ', ' || space || ', and your '
         || 'payment has arrived; Stripe sends the receipt separately. Next we check you '
         || 'are with the team at ' || space || ', then Verified goes on and we email you.' || E'\n\n'
         || case when new.is_new_space
                 then 'Your ' || kind_of || ' is new to us, so it also joins our publishing '
                      || 'queue; we email you the link the moment the page is live.'
                 else 'Your page: ' || coalesce(url, '(link follows once it is live)') end
         || E'\n\n'
         || 'You can already sign in to your Owner account and see where things stand.'
         || owner_line || sig;

  -- Verified claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'awaiting_approval' and new.status = 'paid' then
    kind := 'approved_verified';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := space || ' is Verified on Nomadwise';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: ' || space || ' is now Verified, and your page moves above the free '
         || 'listings in ' || v_city || '. Enquiries sent from your page come straight to '
         || coalesce(nullif(new.enquiry_email, ''), new.owner_email) || '.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'Your page is in our publishing queue; we email you the link when it is live.' || E'\n\n' end
         || 'Next, make the page yours: in your Owner account add your photos, your '
         || 'description, prices and opening hours, and if you like, an event or offer '
         || 'for your page. We read each change before it goes on.'
         || owner_line || sig;

  -- Free claim approved.
  elsif tg_op = 'UPDATE' and old.status = 'free_pending' and new.status = 'free' then
    kind := 'approved_free';
    cta_label := 'Open my Owner account'; cta_url := 'https://nomadmaps.io/owner';
    subj := 'You now manage ' || space || ' on Nomadwise';
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Done: we have confirmed you are with ' || space || ', and you now manage its '
         || 'page on Nomadwise.' || E'\n\n'
         || case when url is not null then 'Your page: ' || url || E'\n\n'
                 else 'The page is in our publishing queue; we check every new page before '
                      || 'it goes live and will email you the link.' || E'\n\n' end
         || 'From your Owner account you can correct the facts and add your own '
         || 'photos, description, prices and opening hours. We read each change before '
         || 'it goes on the page.' || E'\n\n'
         || 'When you want more, Verified is '
         || public.verified_price_words(coalesce((select country from public.venues where id = new.venue_id), new.space_country))
         || ': the Verified badge, a place '
         || 'above the free listings in ' || v_city || ', enquiries straight to your inbox, '
         || 'and your own event or offer on the page. The Go Verified button is in your '
         || 'account.'
         || owner_line || sig;

  -- Rejected.
  elsif tg_op = 'UPDATE' and new.status = 'rejected' and old.status in ('awaiting_approval', 'free_pending') then
    kind := 'rejected';
    subj := 'About your claim for ' || space;
    body := 'Hi ' || first || ',' || E'\n\n'
         || 'Thanks for claiming ' || space || '. We could not confirm the claim as coming '
         || 'from the business, so we have not handed the page over.'
         || case when old.status = 'awaiting_approval'
                 then E'\n\n' || 'Your payment is being refunded in full through Stripe.'
                 else '' end
         || E'\n\n'
         || 'If we have this wrong, reply to this email and tell us who you are at '
         || space || ', and we will sort it out.'
         || sig;
  else
    return new;
  end if;

  perform public.send_owner_email(new.owner_email, subj, body, kind, new.id::text, cta_label, cta_url);
  return new;
exception when others then
  -- Never silent again: a failure here shows in Emails to owners.
  begin
    insert into public.owner_emails (kind, to_email, subject, ref, status, error)
    values ('claim_email', coalesce(lower(new.owner_email), '?'),
            'Claim email for ' || coalesce(new.space_name, 'a space'),
            new.id::text, 'failed', left(sqlerrm, 300));
  exception when others then null; end;
  return new;
end $$;

create or replace function public.nudge_started_claims()
returns integer language plpgsql security definer set search_path = public as $$
declare
  c       record;
  n       integer := 0;
  space   text;
  kind_of text;
  first   text;
  link    text;
  body    text;
  sig     text := E'\n\nJonathan\nNomadwise, https://www.nomadwise.io';
begin
  for c in
    select * from public.listing_claims
     where status = 'started'
       and nudged_at is null
       and coalesce(owner_email, '') <> ''
       and created_at between now() - interval '3 days' and now() - interval '20 hours'
       and not exists (select 1 from public.owner_emails e
                        where e.to_email = lower(listing_claims.owner_email)
                          and e.kind = 'finish_claim')
  loop
    space := coalesce(nullif(c.space_name, ''),
                      (select name from public.venues where id = c.venue_id),
                      'your space');
    kind_of := public.space_kind(coalesce(
                 (select type from public.venues where id = c.venue_id), c.space_type));
    first := coalesce(nullif(split_part(trim(coalesce(c.owner_name, '')), ' ', 1), ''), 'there');
    link  := 'https://nomadmaps.io/?claim=' || replace(space, ' ', '%20');
    body  := 'Hi ' || first || ',' || E'\n\n'
          || 'You started claiming your ' || kind_of || ', ' || space || ', on Nomadwise '
          || 'yesterday and stopped before the last step, so nothing has changed yet.' || E'\n\n'
          || 'Two ways to finish, both take a minute: ' || link || E'\n\n'
          || 'Free: you become the owner of the page and can correct it and add your '
          || 'photos, prices and hours.' || E'\n'
          || 'Verified, '
          || public.verified_price_words(coalesce((select country from public.venues where id = c.venue_id), c.space_country))
          || ': the badge, a place above the free listings in '
          || 'your city, enquiries straight to your inbox, and your own event or offer '
          || 'on the page.' || E'\n\n'
          || 'If something on the form did not work, reply and tell us; we read every '
          || 'answer.'
          || sig;
    perform public.send_owner_email(c.owner_email,
                                    'Finish claiming your ' || kind_of || ', ' || space,
                                    body, 'finish_claim', c.id::text,
                                    'Finish my claim', link);
    update public.listing_claims set nudged_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

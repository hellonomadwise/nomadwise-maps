-- ============================================================
-- Migration 232: places that are not countries, in the pricing
-- dropdown.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 30 Oct 2026: "Madeira isn't in the list. There might be
-- specific places which even though they are not countries, they
-- might be searched for". pricing_for() already knew some of these
-- (pricing_aliases, migration 115) but the dropdown listed countries
-- only. A place now has a label and shows in the list as
-- "Madeira (Portugal)", priced as its country. Spellings without a
-- label (usa, holland, viet nam) stay hidden; they only help
-- pricing_for() read what people type.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.pricing_aliases add column if not exists label text;

insert into public.pricing_aliases (alias, iso, label) values
  ('madeira',          'PT', 'Madeira'),
  ('azores',           'PT', 'Azores'),
  ('canary islands',   'ES', 'Canary Islands'),
  ('tenerife',         'ES', 'Tenerife'),
  ('gran canaria',     'ES', 'Gran Canaria'),
  ('lanzarote',        'ES', 'Lanzarote'),
  ('fuerteventura',    'ES', 'Fuerteventura'),
  ('balearic islands', 'ES', 'Balearic Islands'),
  ('mallorca',         'ES', 'Mallorca'),
  ('majorca',          'ES', null),
  ('ibiza',            'ES', 'Ibiza'),
  ('menorca',          'ES', 'Menorca'),
  ('sicily',           'IT', 'Sicily'),
  ('sardinia',         'IT', 'Sardinia'),
  ('corsica',          'FR', 'Corsica'),
  ('crete',            'GR', 'Crete'),
  ('gozo',             'MT', 'Gozo'),
  ('england',          'GB', 'England'),
  ('scotland',         'GB', 'Scotland'),
  ('wales',            'GB', 'Wales'),
  ('northern ireland', 'GB', 'Northern Ireland'),
  ('dubai',            'AE', 'Dubai'),
  ('zanzibar',         'TZ', 'Zanzibar'),
  ('goa',              'IN', 'Goa'),
  ('bali',             'ID', 'Bali'),
  ('lombok',           'ID', 'Lombok'),
  ('phuket',           'TH', 'Phuket'),
  ('koh samui',        'TH', 'Koh Samui'),
  ('koh phangan',      'TH', 'Koh Phangan'),
  ('langkawi',         'MY', 'Langkawi'),
  ('siargao',          'PH', 'Siargao'),
  ('tasmania',         'AU', 'Tasmania'),
  ('hawaii',           'US', 'Hawaii'),
  ('mexico city',      'MX', 'Mexico City')
on conflict (alias) do update set label = excluded.label;

-- Countries and places together, A to Z. A place carries
-- "value": the word pricing_for() is given when it is chosen.
create or replace function public.pricing_country_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.sort_name), '[]'::jsonb)
    from (
      select pc.name as sort_name,
             jsonb_build_object('iso', pc.iso, 'name', pc.name) as j
        from public.pricing_countries pc
       where coalesce(pc.name, '') <> '' and pc.group_code is not null
      union all
      select pa.label,
             jsonb_build_object('iso', pc.iso,
                                'name', pa.label || ' (' || pc.name || ')',
                                'value', pa.label)
        from public.pricing_aliases pa
        join public.pricing_countries pc on pc.iso = pa.iso
       where coalesce(pa.label, '') <> ''
         and coalesce(pc.name, '') <> '' and pc.group_code is not null
    ) x;
$$;
revoke all on function public.pricing_country_list() from public;
grant execute on function public.pricing_country_list() to anon, authenticated;

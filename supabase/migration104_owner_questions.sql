-- ============================================================
-- Migration 104: one quick question at a time, in the Owner account.
-- (Applied automatically by the build; nothing to paste.)
--
-- Owners see a small "Help shape your Owner account" card with one
-- question and tap an answer (or write their own under "Other").
-- Answers build up over time and show in the control centre (Owners,
-- "What owners tell us"), counted per answer, with every "Other" in
-- the owner's words. No calls, no survey forms.
--
-- Pacing, so it never nags: at most one question per visit, a new one
-- only every 3 days unless the owner taps "Another quick one", and
-- "Not now" puts that question away for 30 days.
--
-- Price questions: the "featured spot" question shows each space one
-- of several prices, picked at random but always the same for that
-- space, so across owners we learn how the answer changes with the
-- price. Prices are in euro for euro countries, pounds in the UK and
-- dollars elsewhere.
--
-- Questions live in owner_questions: to change one, update its text
-- or options; to stop asking it, set active = false; to add one,
-- insert a row. Placeholders: {c} is the currency symbol, {price}
-- the price being tested.
-- ============================================================

create table if not exists public.owner_questions (
  key          text primary key,
  sort         integer not null default 100,
  prompt       text not null,
  help         text,
  options      jsonb not null default '[]'::jsonb,
  multi        boolean not null default false,
  allow_other  boolean not null default true,
  price_test   jsonb,          -- e.g. [5, 9, 15, 25, 39]
  only_tier    text check (only_tier in ('free', 'verified')),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
alter table public.owner_questions enable row level security;
drop policy if exists "owner_questions admin" on public.owner_questions;
create policy "owner_questions admin" on public.owner_questions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists public.owner_answers (
  id            uuid primary key default gen_random_uuid(),
  question_key  text not null references public.owner_questions(key) on update cascade on delete cascade,
  venue_id      uuid references public.venues(id) on delete set null,
  owner_email   text not null,
  choices       text[] not null default '{}',
  other         text check (char_length(other) <= 1000),
  skipped       boolean not null default false,
  shown         jsonb,          -- the question exactly as the owner saw it
  created_at    timestamptz not null default now(),
  unique (question_key, owner_email)
);
create index if not exists idx_owner_answers_created on public.owner_answers(created_at desc);
alter table public.owner_answers enable row level security;
drop policy if exists "owner_answers admin" on public.owner_answers;
create policy "owner_answers admin" on public.owner_answers
  for select to authenticated using (public.is_admin());

-- The questions to start with. Re-running keeps any edits made since.
insert into public.owner_questions (key, sort, prompt, help, options, multi, price_test) values
  ('find_you', 10,
   'How do most new people find your space today?',
   'Pick any that apply.',
   '["Google or Google Maps", "Instagram or other social media", "Word of mouth", "Booking or listing sites", "Walking past", "Our own website"]',
   true, null),
  ('biggest_help', 20,
   'What would help your space most right now?',
   null,
   '["More members or regular customers", "More day-pass or drop-in visitors", "More bookings for rooms or events", "Being easier to find online", "Less time spent on admin"]',
   false, null),
  ('extras_useful', 30,
   'Which of these would be useful for your space?',
   'Pick any. We build the most picked first.',
   '["Enquiries from remote workers sent straight to you", "A featured spot at the top of your city", "Your events and offers shown on your page", "A poster and badge with your tested WiFi speed", "Reviews from remote workers who worked there", "A button to book a day pass"]',
   true, null),
  ('pay_rhythm', 40,
   'If you chose a paid extra, how would you rather pay?',
   null,
   '["Monthly", "Yearly, with a discount", "Either is fine", "I would rather not pay for extras"]',
   false, null),
  ('price_format', 50,
   'Which of these feels better to you?',
   'The same price, paid two ways.',
   '["{c}9 a month", "{c}90 a year (2 months free)", "No difference to me"]',
   false, null),
  ('price_featured', 60,
   'Would a featured spot at the top of your city be worth {price} a month to you?',
   'Your space shown first when remote workers look at your city, clearly marked as featured.',
   '["Yes, easily", "Probably", "Only if it were cheaper", "Not for us"]',
   false, '[5, 9, 15, 25, 39]'),
  ('marketing_spend', 70,
   'Roughly what do you spend on marketing in a typical month?',
   'Ads, listing sites, social media, anything that brings people in.',
   '["Nothing", "Under {c}50", "{c}50 to {c}200", "{c}200 to {c}500", "More than {c}500", "I would rather not say"]',
   false, null),
  ('member_value', 80,
   'What does a regular member or customer usually spend with you in a month?',
   null,
   '["Under {c}50", "{c}50 to {c}150", "{c}150 to {c}300", "More than {c}300", "I would rather not say"]',
   false, null),
  ('decides', 90,
   'Who decides on spending like this for your space?',
   null,
   '["Just me", "Me and a partner or team", "A head office or board"]',
   false, null)
on conflict (key) do nothing;

-- Euro, pound or dollar for a space's country.
create or replace function public.owner_currency_symbol(p_country text)
returns text language sql immutable as $$
  select case
    when lower(coalesce(p_country, '')) in (
      'austria','belgium','croatia','cyprus','estonia','finland','france',
      'germany','greece','ireland','italy','latvia','lithuania','luxembourg',
      'malta','netherlands','the netherlands','portugal','slovakia','slovenia',
      'spain','montenegro','kosovo','andorra','monaco','san marino','vatican city')
      then '€'
    when lower(coalesce(p_country, '')) in ('uk', 'united kingdom', 'england', 'scotland', 'wales', 'northern ireland')
      then '£'
    else '$'
  end;
$$;

-- The next question for this owner and space, filled in, or null.
-- p_more: the owner asked for another one right now.
create or replace function public.owner_next_question(p_venue uuid, p_more boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em      text := public.owner_email();
  v       public.venues%rowtype;
  q       public.owner_questions%rowtype;
  c       text;
  price   numeric;
  opts    jsonb;
  prompt  text;
  left_n  integer;
begin
  if em is null then return null; end if;
  select * into v from public.venues
   where id = p_venue and lower(listing_owner_email) = em;
  if not found then return null; end if;

  -- Not more than one new question every 3 days, unless asked for.
  if not coalesce(p_more, false) and exists (
       select 1 from public.owner_answers a
        where a.owner_email = em and a.created_at > now() - interval '3 days') then
    return null;
  end if;

  select * into q from public.owner_questions x
   where x.active
     and (x.only_tier is null or x.only_tier = coalesce(v.listing_tier, 'free'))
     and not exists (
       select 1 from public.owner_answers a
        where a.question_key = x.key and a.owner_email = em
          and (not a.skipped or a.created_at > now() - interval '30 days'))
   order by x.sort, x.key
   limit 1;
  if not found then return null; end if;

  select count(*) into left_n from public.owner_questions x
   where x.active
     and (x.only_tier is null or x.only_tier = coalesce(v.listing_tier, 'free'))
     and not exists (
       select 1 from public.owner_answers a
        where a.question_key = x.key and a.owner_email = em
          and (not a.skipped or a.created_at > now() - interval '30 days'));

  c := public.owner_currency_symbol(v.country);
  if jsonb_typeof(q.price_test) = 'array' and jsonb_array_length(q.price_test) > 0 then
    -- The same price for this space every time, spread across spaces.
    price := (q.price_test ->> mod(abs(hashtext(v.id::text || q.key)::bigint), jsonb_array_length(q.price_test))::integer)::numeric;
  end if;

  prompt := replace(replace(q.prompt, '{c}', c), '{price}', coalesce(c || price::text, ''));
  select coalesce(jsonb_agg(to_jsonb(replace(replace(o, '{c}', c), '{price}', coalesce(c || price::text, ''))) order by n), '[]'::jsonb)
    into opts
    from jsonb_array_elements_text(q.options) with ordinality as t(o, n);

  return jsonb_build_object(
    'key', q.key,
    'prompt', prompt,
    'help', replace(replace(coalesce(q.help, ''), '{c}', c), '{price}', coalesce(c || price::text, '')),
    'options', opts,
    'multi', q.multi,
    'allow_other', q.allow_other,
    'price', price,
    'currency', c,
    'remaining', left_n);
end $$;
grant execute on function public.owner_next_question(uuid, boolean) to authenticated;

-- Save an answer (or "Not now"). Answering again replaces it.
create or replace function public.owner_answer_question(
  p_venue uuid, p_key text, p_choices text[], p_other text, p_skip boolean, p_shown jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  em text := public.owner_email();
begin
  if em is null then raise exception 'Please sign in again.'; end if;
  if not exists (select 1 from public.venues
                  where id = p_venue and lower(listing_owner_email) = em) then
    raise exception 'This space is not in your Owner account.';
  end if;
  if not exists (select 1 from public.owner_questions where key = p_key) then
    raise exception 'That question is no longer asked.';
  end if;
  insert into public.owner_answers (question_key, venue_id, owner_email, choices, other, skipped, shown)
  values (p_key, p_venue, em,
          coalesce(p_choices, '{}'),
          nullif(left(trim(coalesce(p_other, '')), 1000), ''),
          coalesce(p_skip, false),
          p_shown)
  on conflict (question_key, owner_email) do update
     set venue_id = excluded.venue_id,
         choices = excluded.choices,
         other = excluded.other,
         skipped = excluded.skipped,
         shown = excluded.shown,
         created_at = now();
end $$;
grant execute on function public.owner_answer_question(uuid, text, text[], text, boolean, jsonb) to authenticated;

-- Control centre: every question with its answers counted, the
-- "Other" answers in full, and for price questions the answers per
-- price shown.
create or replace function public.admin_owner_insights()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  out jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', q.key,
      'prompt', q.prompt,
      'options', q.options,
      'multi', q.multi,
      'active', q.active,
      'price_test', q.price_test,
      'answered', (select count(*) from public.owner_answers a
                    where a.question_key = q.key and not a.skipped),
      'skipped', (select count(*) from public.owner_answers a
                   where a.question_key = q.key and a.skipped),
      'answers', (select coalesce(jsonb_agg(jsonb_build_object(
                      'choices', a.choices,
                      'other', a.other,
                      'price', a.shown ->> 'price',
                      'currency', a.shown ->> 'currency',
                      'venue', v.name,
                      'venue_id', a.venue_id,
                      'city', v.city,
                      'country', v.country,
                      'tier', v.listing_tier,
                      'at', a.created_at) order by a.created_at desc), '[]'::jsonb)
                    from public.owner_answers a
                    left join public.venues v on v.id = a.venue_id
                   where a.question_key = q.key and not a.skipped)
    ) order by q.sort, q.key), '[]'::jsonb)
    into out
    from public.owner_questions q;
  return out;
end $$;
revoke all on function public.admin_owner_insights() from public;
grant execute on function public.admin_owner_insights() to authenticated;

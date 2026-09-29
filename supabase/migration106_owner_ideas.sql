-- ============================================================
-- Migration 106: owners help decide what we build next.
-- (Applied automatically by the build; nothing to paste.)
--
-- The Owner account gets a "Build next" tab: a list of tools we could
-- make for spaces, each with a one-line description. Owners vote for
-- as many as they like (a tap turns a vote on or off) and can write
-- their own idea. The control centre (Owners, What owners tell us)
-- shows the ideas ranked by votes, who voted, and every idea owners
-- wrote.
--
-- Ideas live in owner_ideas: change a title or line with an update,
-- stop showing one with active = false, add one with an insert.
-- ============================================================

create table if not exists public.owner_ideas (
  key        text primary key,
  sort       integer not null default 100,
  title      text not null,
  blurb      text,
  icon       text,               -- a Material icon name the app knows
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.owner_ideas enable row level security;
drop policy if exists "owner_ideas admin" on public.owner_ideas;
create policy "owner_ideas admin" on public.owner_ideas
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists public.owner_idea_votes (
  idea_key    text not null references public.owner_ideas(key) on update cascade on delete cascade,
  owner_email text not null,
  venue_id    uuid references public.venues(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (idea_key, owner_email)
);
alter table public.owner_idea_votes enable row level security;
drop policy if exists "owner_idea_votes admin" on public.owner_idea_votes;
create policy "owner_idea_votes admin" on public.owner_idea_votes
  for select to authenticated using (public.is_admin());

create table if not exists public.owner_idea_suggestions (
  id          uuid primary key default gen_random_uuid(),
  owner_email text not null,
  venue_id    uuid references public.venues(id) on delete set null,
  text        text not null check (char_length(text) between 3 and 1500),
  created_at  timestamptz not null default now()
);
alter table public.owner_idea_suggestions enable row level security;
drop policy if exists "owner_idea_suggestions admin" on public.owner_idea_suggestions;
create policy "owner_idea_suggestions admin" on public.owner_idea_suggestions
  for select to authenticated using (public.is_admin());

-- The ideas to start with. Re-running keeps any edits made since.
insert into public.owner_ideas (key, sort, title, blurb, icon) values
  ('day_pass_booking', 10, 'Book a day pass on your page',
   'Remote workers pick a day and pay online before they arrive, so they turn up ready to work.',
   'event_available'),
  ('enquiry_inbox', 20, 'All your enquiries in one place',
   'See and answer every enquiry from remote workers here, instead of hunting through your email.',
   'inbox'),
  ('events', 30, 'Your events on the map',
   'Post workshops, meetups and community events, shown on your page and to remote workers nearby.',
   'celebration'),
  ('nomad_offers', 40, 'Offers for remote workers',
   'Run a welcome offer, like a free first coffee or a discounted first week, for people who find you through Nomadwise.',
   'local_offer'),
  ('wifi_poster', 50, 'A WiFi-tested poster and badge',
   'A printable poster with your tested WiFi speed and a QR code to your page, for your door or front desk.',
   'wifi'),
  ('reviews', 60, 'Reviews from remote workers',
   'Short reviews from people who actually worked at your space, shown on your page.',
   'rate_review'),
  ('memberships', 70, 'Sell memberships through your page',
   'Weekly and monthly memberships remote workers can buy online, with you paid directly.',
   'card_membership'),
  ('team_access', 80, 'Your team can help',
   'Invite colleagues to keep the page up to date, each with their own sign-in.',
   'group_add'),
  ('social_posts', 90, 'Ready-made posts for your socials',
   'Instagram-ready images made from your page, your photos and your WiFi speed, to share in a tap.',
   'photo_library'),
  ('city_feature', 100, 'Featured in your city',
   'A clearly marked featured spot at the top of your city and area pages.',
   'star')
on conflict (key) do nothing;

-- The ideas for this owner, with their own votes.
create or replace function public.owner_ideas_for(p_venue uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  em text := public.owner_email();
begin
  if em is null then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'key', i.key, 'title', i.title, 'blurb', i.blurb, 'icon', i.icon,
      'voted', exists (select 1 from public.owner_idea_votes v
                        where v.idea_key = i.key and v.owner_email = em))
      order by i.sort, i.key), '[]'::jsonb)
    from public.owner_ideas i where i.active);
end $$;
grant execute on function public.owner_ideas_for(uuid) to authenticated;

-- A vote on or off.
create or replace function public.owner_vote_idea(p_venue uuid, p_key text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  em text := public.owner_email();
begin
  if em is null then raise exception 'Please sign in again.'; end if;
  if not exists (select 1 from public.venues
                  where id = p_venue and lower(listing_owner_email) = em) then
    raise exception 'This space is not in your Owner account.';
  end if;
  if coalesce(p_on, false) then
    insert into public.owner_idea_votes (idea_key, owner_email, venue_id)
    values (p_key, em, p_venue)
    on conflict (idea_key, owner_email) do nothing;
  else
    delete from public.owner_idea_votes where idea_key = p_key and owner_email = em;
  end if;
end $$;
grant execute on function public.owner_vote_idea(uuid, text, boolean) to authenticated;

-- An owner's own idea, in their words.
create or replace function public.owner_suggest_idea(p_venue uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  em text := public.owner_email();
  t  text := left(trim(coalesce(p_text, '')), 1500);
begin
  if em is null then raise exception 'Please sign in again.'; end if;
  if not exists (select 1 from public.venues
                  where id = p_venue and lower(listing_owner_email) = em) then
    raise exception 'This space is not in your Owner account.';
  end if;
  if char_length(t) < 3 then raise exception 'Write a few words about your idea.'; end if;
  insert into public.owner_idea_suggestions (owner_email, venue_id, text)
  values (em, p_venue, t);
end $$;
grant execute on function public.owner_suggest_idea(uuid, text) to authenticated;

-- Control centre: ideas ranked by votes, who voted, and owners' own ideas.
create or replace function public.admin_owner_ideas()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'ideas', (select coalesce(jsonb_agg(x order by (x->>'votes')::int desc, x->>'title'), '[]'::jsonb)
                from (select jsonb_build_object(
                        'key', i.key, 'title', i.title, 'active', i.active,
                        'votes', (select count(*) from public.owner_idea_votes v where v.idea_key = i.key),
                        'voters', (select coalesce(jsonb_agg(coalesce(ve.name, v.owner_email) order by v.created_at desc), '[]'::jsonb)
                                     from public.owner_idea_votes v
                                     left join public.venues ve on ve.id = v.venue_id
                                    where v.idea_key = i.key)) as x
                        from public.owner_ideas i) q),
    'suggestions', (select coalesce(jsonb_agg(jsonb_build_object(
                        'text', s.text, 'venue', ve.name, 'city', ve.city,
                        'email', s.owner_email, 'at', s.created_at)
                        order by s.created_at desc), '[]'::jsonb)
                      from public.owner_idea_suggestions s
                      left join public.venues ve on ve.id = s.venue_id),
    'voters_total', (select count(distinct owner_email) from public.owner_idea_votes));
end $$;
revoke all on function public.admin_owner_ideas() from public;
grant execute on function public.admin_owner_ideas() to authenticated;

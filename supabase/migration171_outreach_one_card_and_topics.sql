-- 171: Outreach, one card per space, and what each conversation was
-- about.
--
-- Jonathan, 8 Oct 2026, on Outreach: "why are there 2 boxes here for
-- the same space?" (Lisbon Cowork: the old Gmail import of their
-- affiliate approval, and the line made when the owner claimed on
-- 7 Oct with another address), and "there is a bunch of spaces here
-- with email trails where I'm unsure if they are relevant to potential
-- outreach ... for Sierra Cartel, the email content i think is to do
-- with gst registration ... in the context of this content written
-- here, its not relevant". He chose all of it:
--
--   * One card per space. A line Outreach made by itself for a space
--     (source 'listing' or 'claim', nothing ever received on it) is
--     folded into the space's other card, with its messages and notes;
--     every night too, so it does not come back. And seven pairs found
--     by reading the trails (the same business written to from two
--     addresses) are joined here, by hand.
--   * A topic on each card, from what the conversation was about:
--     listing, booking (we sent them a guest), partnership, other
--     business, not a fit (asked to be removed, closed, or not a space
--     for us), recommendation (a user told us about it). Set for the
--     85 cards that came from the inbox and the forms, from reading
--     each trail; changeable on the card.
--   * "Other business" and "not a fit" are set aside: out of the list
--     and the numbers, under their own chip "Not for outreach", and
--     still found by searching. A space that has claimed or pays is
--     never set aside.
--   * A template for spaces we know from a booking or partnership
--     talk, so they are not thanked for asking to be listed.
-- Safe to apply twice.

alter table public.space_contacts
  add column if not exists topic text;
do $$
begin
  alter table public.space_contacts
    add constraint space_contacts_topic_check
    check (topic in ('listing', 'booking', 'partnership', 'other', 'not_a_fit', 'recommendation'));
exception when duplicate_object then
  null;
end $$;

-- Set aside from outreach: other business, or not a fit, unless the
-- space has claimed or pays.
create or replace function public.outreach_aside(p_topic text, p_stage text)
returns boolean language sql immutable as $$
  select coalesce(p_topic in ('other', 'not_a_fit'), false)
         and coalesce(p_stage, '') not in ('claimed', 'verified');
$$;

-- ------------------------------------------------ joining two cards
-- Everything of p_drop goes to p_keep: its messages, its notes, the
-- details p_keep lacks, the further stage, the earliest first and
-- latest last dates. An unsubscribe on either stays. p_drop is then
-- removed. Returns false when either is missing or they are the same.
create or replace function public.outreach_merge(p_keep uuid, p_drop uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  k public.space_contacts%rowtype;
  d public.space_contacts%rowtype;
  rank_k integer;
  rank_d integer;
  extra text;
begin
  if p_keep is null or p_drop is null or p_keep = p_drop then
    return false;
  end if;
  select * into k from public.space_contacts where id = p_keep for update;
  if not found then return false; end if;
  select * into d from public.space_contacts where id = p_drop for update;
  if not found then return false; end if;

  -- how far along each is
  rank_k := array_position(array['new', 'contacted', 'replied', 'not_now', 'declined',
                                 'bounced', 'claimed', 'verified', 'unsubscribed'], k.stage);
  rank_d := array_position(array['new', 'contacted', 'replied', 'not_now', 'declined',
                                 'bounced', 'claimed', 'verified', 'unsubscribed'], d.stage);

  -- a second address is kept in the notes, not lost
  if d.email is not null and k.email is not null and lower(d.email) <> lower(k.email) then
    extra := 'Also wrote from ' || d.email
             || coalesce(' (' || nullif(btrim(d.person_name), '') || ')', '') || '.';
  end if;

  update public.outreach_messages set contact_id = k.id where contact_id = d.id;
  delete from public.space_contacts where id = d.id;

  update public.space_contacts c
     set venue_id    = coalesce(k.venue_id, d.venue_id),
         space_name  = coalesce(k.space_name, d.space_name),
         kind        = coalesce(k.kind, d.kind),
         city        = coalesce(k.city, d.city),
         country     = coalesce(k.country, d.country),
         person_name = coalesce(k.person_name, d.person_name),
         email       = coalesce(k.email, d.email),
         phone       = coalesce(k.phone, d.phone),
         website     = coalesce(k.website, d.website),
         instagram   = coalesce(k.instagram, d.instagram),
         topic       = coalesce(k.topic, d.topic),
         stage       = case when coalesce(rank_d, 0) > coalesce(rank_k, 0) then d.stage else k.stage end,
         stage_at    = case when coalesce(rank_d, 0) > coalesce(rank_k, 0) then d.stage_at else k.stage_at end,
         first_in_at = least(k.first_in_at, d.first_in_at),
         last_in_at  = greatest(k.last_in_at, d.last_in_at),
         last_out_at = greatest(k.last_out_at, d.last_out_at),
         follow_up_on = coalesce(k.follow_up_on, d.follow_up_on),
         unsubscribed_at = coalesce(k.unsubscribed_at, d.unsubscribed_at),
         -- the other card's notes, without lines it already has
         notes = nullif(concat_ws(E'\n', nullif(k.notes, ''),
                   (select string_agg(l, E'\n')
                      from unnest(string_to_array(coalesce(d.notes, ''), E'\n')) l
                     where btrim(l) <> ''
                       and position(btrim(l) in coalesce(k.notes, '')) = 0),
                   extra), ''),
         updated_at = now()
   where c.id = k.id;
  return true;
end $$;
revoke all on function public.outreach_merge(uuid, uuid) from public, anon, authenticated;
grant execute on function public.outreach_merge(uuid, uuid) to service_role;

-- A line Outreach made by itself for a space ('listing' or 'claim'),
-- with nothing ever received on it, folded into the space's other
-- card (the one with a conversation, else the oldest). Returns how
-- many were folded.
create or replace function public.outreach_fold_duplicates()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  keep uuid;
  n integer := 0;
begin
  for r in
    select c.id, c.venue_id
      from public.space_contacts c
     where c.venue_id is not null
       and not c.is_test
       and c.source in ('listing', 'claim')
       and c.last_in_at is null
       and not exists (select 1 from public.outreach_messages m
                        where m.contact_id = c.id and m.direction = 'in')
       and exists (select 1 from public.space_contacts o
                    where o.venue_id = c.venue_id and o.id <> c.id and not o.is_test)
  loop
    -- still there (an earlier pass may have taken it), and the card to keep
    continue when not exists (select 1 from public.space_contacts where id = r.id);
    select o.id into keep
      from public.space_contacts o
     where o.venue_id = r.venue_id and o.id <> r.id and not o.is_test
     order by (o.source in ('listing', 'claim')) asc,
              (select count(*) from public.outreach_messages m where m.contact_id = o.id) desc,
              o.created_at, o.id
     limit 1;
    if keep is not null and public.outreach_merge(keep, r.id) then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.outreach_fold_duplicates() from public, anon, authenticated;
grant execute on function public.outreach_fold_duplicates() to service_role;

select public.outreach_fold_duplicates();

do $$
begin
  perform cron.unschedule('outreach-fold');
exception when others then null;
end $$;
do $$
begin
  perform cron.schedule('outreach-fold', '40 3 * * *',
    'select public.outreach_fold_duplicates()');
exception when others then
  raise warning 'outreach-fold not scheduled: %', sqlerrm;
end $$;

-- The same business written to from two addresses, joined by hand
-- (8 Oct 2026). Nothing happens when either card is already gone.
select public.outreach_merge(k::uuid, d::uuid)
  from (values
    -- KAPTAR Coworking: hello@ (listing) and peter@ (a booking)
    ('ddc5d979-4f34-4d48-b98f-489ca99c1751', '32817d5c-83da-4c83-8853-ab4d502be24e'),
    -- The Work Loft: the email and its website-chat reply
    ('a8164312-bcc8-4c3f-a48d-1209d7e69a1b', '486b5f7c-8c4e-4e87-b1a9-d8b0eb58c05f'),
    -- Ofis Voyvoda: the space we set up, and Aytek's photos
    ('d25b8cee-ea80-4ee3-a74e-5bc33185c0d8', 'f0095b78-50cb-4558-8dea-64cc9b16c589'),
    -- Nomio Coworking Lounge: the space we set up, and LiveNomio's emails
    ('b6cca755-8b8b-44c6-991b-46bea6153d1a', 'c55b375a-c1c1-471d-95a7-8c22dc0f9a72'),
    -- Monday: the space we set up, and the Monday Coworking emails
    ('0bf1114c-a602-4635-9d29-f7881814282d', '7ed82ed0-2ec6-48cf-a9c7-67ef2d2a989d'),
    -- ViOS Coworking: xc@ (a booking) and gl@ (photos of three locations)
    ('df66b0d8-5806-463f-830f-1740cf24db22', '358a386d-6ccc-4303-87ba-d8a5bd7609ad'),
    -- Lisbon Cowork: the affiliate email, and the line made at the claim
    -- (also caught by the fold above; here in case it was not)
    ('322bae8a-a64c-4aa0-87b1-25f379afce48', 'e2dc535c-7893-443f-8996-ac4c30b6fafe')
  ) p(k, d)
 where exists (select 1 from public.space_contacts where id = p.k::uuid)
   and exists (select 1 from public.space_contacts where id = p.d::uuid);

-- What each conversation was about, from reading the trails (8 Oct
-- 2026). Only cards without a topic yet: a topic set on the card is
-- never overwritten.
update public.space_contacts c
   set topic = t.topic
  from (values
    ('f275e3c2-5f37-452e-9d21-7517ffa04849', 'other'),          -- Sierra Cartel: a virtual-office lead
    ('322bae8a-a64c-4aa0-87b1-25f379afce48', 'other'),          -- Lisbon Cowork: affiliate approval (claimed, so not set aside)
    ('7412fe53-8aad-4874-87e3-8f31e74c7a04', 'listing'),        -- Workspace 6
    ('2d4446c5-6464-4a2c-9738-813a95679cbd', 'partnership'),    -- SOKKOOL
    ('31eb8f59-41c2-4ce1-ace8-2d60fa2020a5', 'listing'),        -- Westerwelle Startup Haus Arusha
    ('d703cb37-763e-4857-995e-0335eebae2b7', 'listing'),        -- Arvian Coworking
    ('a58ec2de-f98a-448d-8e75-ba6219082d51', 'listing'),        -- Aspire Coworks
    ('ada25dd1-3fb4-43f6-9c90-9b787fc7a2b5', 'listing'),        -- AT 06
    ('b95d79a4-176c-478e-8c49-8728f2a4f729', 'booking'),        -- Avila Spaces
    ('f9cd445a-b351-4084-9b5f-4e7231ba676f', 'booking'),        -- Avila Spaces (Atrium Saldanha)
    ('e0704d6d-cade-4eaf-88e0-009ad59b835c', 'booking'),        -- Beachub (a booking agent)
    ('155fc117-cb88-4df9-90e5-a21ec90aa20f', 'listing'),        -- Behongli
    ('56ee114c-efe8-4829-91f7-8ae162621ead', 'not_a_fit'),      -- Beluna: no longer coworking
    ('6f13f95e-15e5-4838-be31-f94241aa365e', 'listing'),        -- BHT Hive Five
    ('8fe88bbb-3c95-4d21-ab7f-d4a383e90d21', 'listing'),        -- Cadaver Exquisit
    ('56d9bf3e-446c-461b-b370-6262f958cf2f', 'listing'),        -- Cafe Noina
    ('3afeb651-4e4e-4496-8a78-2a49f296be89', 'partnership'),    -- Camp 308
    ('aa33b2f8-bf51-441e-9c10-583730965583', 'listing'),        -- Coco Space
    ('f393027a-eec3-4c70-b5aa-920d7744c1bf', 'listing'),        -- Comeet
    ('16a74142-d78e-4462-9fec-caf9c5bdd5d7', 'partnership'),    -- Common Ground
    ('f7a76f5c-7b54-448b-8f7d-f85e7f20e6d8', 'not_a_fit'),      -- CORE Oldenburg: asked for removal
    ('75d6a29a-26f6-44a9-ad6b-7b478f58d186', 'listing'),        -- COSP Glashuetten
    ('81adba32-583d-4b62-90d3-0a8fad2b7a69', 'booking'),        -- Cowork Funchal
    ('f104f9bb-2dd9-4881-821a-898da93a9407', 'listing'),        -- Danasol
    ('1c4d3640-352b-4055-b047-c59b7488e772', 'listing'),        -- ecos Hannover
    ('69a6c314-f22d-4ac4-b6cb-e1220580e32a', 'listing'),        -- Flow Workspace Bali
    ('313e59be-ef06-4051-bf2d-76e146d857fa', 'listing'),        -- French Kiss Paris
    ('11420ec5-03d5-46b4-9691-84ed2e2380c6', 'not_a_fit'),      -- Glaswerk: no longer public coworking
    ('d7f1ca8d-6837-47a7-adbd-2e7488a232ec', 'listing'),        -- House of Eors
    ('b630f7ed-209a-4635-aa48-cef30e90955c', 'listing'),        -- Itnig
    ('2052b1e3-c8f0-4322-bc6d-9009ba399fc7', 'listing'),        -- Jiboia Studio
    ('dc9251cf-5ed6-4a7e-931b-b3400b13bbe7', 'listing'),        -- Jobetter Space
    ('ddc5d979-4f34-4d48-b98f-489ca99c1751', 'listing'),        -- KAPTAR
    ('95f3871f-f6e8-4dfb-b6d4-ddf1a1d018e9', 'other'),          -- Kawisari: a PR pitch
    ('7c7f6aa5-722d-4b12-8765-a5328b7f899a', 'partnership'),    -- Kelp Cowork
    ('68bb3d85-bccc-4600-a47c-71f293891d92', 'not_a_fit'),      -- KUDO: no longer coworking
    ('48ad1f92-7ea9-4e77-ac56-00c7c6d25412', 'listing'),        -- Linuxx
    ('55c6b053-25be-46bf-8598-9ea86726e0bf', 'listing'),        -- Madeira Friends Hub
    ('aced2e11-4c0b-4e5d-b02e-715b622d1114', 'not_a_fit'),      -- Magical Garden: also a cannabis lounge
    ('7c7cf3d8-b256-4d8e-9fcb-2bf620def099', 'not_a_fit'),      -- MAGNETIC: not a real space
    ('77905e1b-53da-4e0f-a0d2-0877c3e3e210', 'other'),          -- myOffice: a sales package
    ('20203459-fae6-4866-87cb-1164edeb9346', 'booking'),        -- Palo Alto Club
    ('1424205a-d74b-4295-baac-651d8dc9acef', 'listing'),        -- redNERD
    ('874694fa-f9b1-42bb-ab01-99288d7054cf', 'listing'),        -- Rhodes Project
    ('7be70c85-d3d2-4f7f-addd-aaa935cc3739', 'partnership'),    -- Selina Lisbon / Ericeira
    ('a96eb101-8abb-4417-a85e-63f6ba9da5ba', 'partnership'),    -- Selina Portugal
    ('d5635d7c-c219-4041-b971-c476edfb4eaf', 'booking'),        -- Selina Secret Garden
    ('087d3db7-3672-44c2-b4a5-da40e79eb068', 'listing'),        -- Shinei
    ('e13f705e-8fa0-48c4-af15-f55c923547a4', 'not_a_fit'),      -- StartUp Nijmegen: removed, long contracts only
    ('14a73db4-f299-44c9-a745-2cf15759e953', 'listing'),        -- Stone Soup
    ('63c6e9dd-d504-424c-bb75-b72bb549385a', 'listing'),        -- STUDIOS 94
    ('5e607cfb-c64f-4fbc-8fd5-0f5a2bbbaf94', 'listing'),        -- the (co)lab
    ('66217c61-b207-456b-8cde-6fe586ea2abe', 'not_a_fit'),      -- The Unit: asked not to be published
    ('d90022f8-05a4-41d4-986b-07aca37dc25a', 'not_a_fit'),      -- The Urban Office: asked to be taken down
    ('a8164312-bcc8-4c3f-a48d-1209d7e69a1b', 'booking'),        -- The Work Loft
    ('6f527e79-aabe-4a1f-9183-f05877ec964a', 'booking'),        -- Tribe Social Club
    ('e2c4b6ff-2bbd-4d1c-a1d0-171b40dbb58d', 'partnership'),    -- Uncommon Borough
    ('df66b0d8-5806-463f-830f-1740cf24db22', 'booking'),        -- ViOS
    ('a58090df-936a-4668-9770-a90bdca24267', 'listing'),        -- Working From_ Southwark
    ('5ca4f79c-085f-4bdd-8700-7747ff2b0f56', 'listing'),        -- WORX
    ('0ab4b1d4-e9a7-40da-9c4f-0a709d5ce3b5', 'booking'),        -- WRKLAND
    ('0964d67a-dacf-4262-b8b9-fa0a547f036e', 'partnership'),    -- Yolk House
    ('62552a29-7ea7-4a7e-90eb-85ce7bfecb06', 'recommendation'), -- Amsiln Studio
    ('2732736d-97b4-4ba0-b9c0-a6ac35b94825', 'recommendation'), -- ARTEFACT
    ('7473487f-5696-48bb-b605-c78d2ceac8b6', 'recommendation'), -- Coco's cafe
    ('371b78c3-7170-4c16-b05f-690ca10e4339', 'recommendation'), -- Finexis
    ('7db7f98d-8329-439c-aa09-93d6ca1ea98d', 'not_a_fit'),      -- Foods & Roots: laptops not allowed
    ('98f8e4a2-2f55-4bc4-8369-c86e629a5a47', 'recommendation'), -- Hiltl Sihlpost
    ('d1928305-1fbc-4407-8c62-5c4bcba27b01', 'recommendation'), -- TaoHub
    ('558048f0-9f75-4878-a876-22625483001e', 'recommendation'), -- The Shed
    ('6d4c4b47-c574-47c9-b235-7a3b48a7f8f7', 'listing')         -- Yes Surf Siargao
  ) t(id, topic)
 where c.id = t.id::uuid
   and c.topic is null;

-- Changing it on the card.
create or replace function public.admin_outreach_set_topic(p_id uuid, p_topic text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_topic is not null and p_topic not in
     ('listing', 'booking', 'partnership', 'other', 'not_a_fit', 'recommendation') then
    raise exception 'Unknown topic.';
  end if;
  update public.space_contacts set topic = p_topic, updated_at = now() where id = p_id;
end $$;
revoke all on function public.admin_outreach_set_topic(uuid, text) from public, anon;
grant execute on function public.admin_outreach_set_topic(uuid, text) to authenticated;

-- ------------------------------------------------ a template for spaces we know
-- For a space we already know from a booking or a partnership talk:
-- no "thank you for asking to be listed". Added once; Jonathan's own
-- changes in Outreach, Templates are never overwritten.
insert into public.outreach_templates (key, name, subject, body, stream, sort) values
('reply_we_know_you', 'Owner account: a space we know (booking or partnership)',
 'Your page on Nomadwise: {space}',
 'Hi {first_name},

We have been in touch before about {space}, and I wanted to tell you about something new.

{space} is on nomadwise.io: {page_link}

You can now take the page over yourself, free, from your own Owner account. Claim it here: {claim_link}

From there you can update your opening hours and contact details, and add your own photos, description and prices. Every change is read by a person before it goes live. If you would like the Verified badge, a place above every free listing in your city and enquiries straight to your inbox, that is {price_words}, monthly or yearly, cancel any time.

{signoff}', 'outbound', 25)
on conflict (key) do nothing;

-- ------------------------------------------------ the list and the numbers
-- As migrations 156 and 150, with the topic on each line, and the set
-- aside lines only under "Not for outreach" (p_stage 'aside') or a
-- search.
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
    select jsonb_agg(row_to_json(x)::jsonb order by x.sort_at desc nulls last, x.sort_first, x.space_name)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at, c.is_test, c.topic,
               public.outreach_aside(c.topic, c.stage) as aside,
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
               -- The latest thing that happened on the line, whoever did
               -- it: they wrote, we wrote, its stage changed, its claim
               -- page was opened, an account was made, or the owner was
               -- in their Owner account. (Jonathan, 7 Oct 2026: "can
               -- you make most recent activity on top".)
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at),
                        c.stage_at, l.last_at, su.signed_up_at,
                        a.signed_in_at, a.last_open, a.last_did) as sort_at,
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
           -- "Not for outreach" (migration 171): only under its own
           -- chip, or when searched for by name
           and (case when st = '' and coalesce(p_stage, '') = 'aside'
                     then public.outreach_aside(c.topic, c.stage)
                     else (not public.outreach_aside(c.topic, c.stage) or q <> '') end)
           -- the chips: "Set up by us" has its own, and those lines are
           -- not under Claimed or Verified
           and (st <> '' or coalesce(p_stage, '') in ('', 'tests', 'aside')
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
         order by sort_at desc nulls last, sort_first, space_name
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

create or replace function public.admin_outreach_counts(p_group text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  -- Spaces we set up and nobody has claimed (see admin_outreach_path)
  -- are counted as "ours", not as Claimed or Verified.
  with ours as materialized (
    select a.venue_id from public.outreach_owner_activity() a
     where not (a.claimed_self or a.signed_in_at is not null or a.opens > 0
                or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0)
  )
  select case when public.is_admin() then
    coalesce((select jsonb_object_agg(stage, n)
                from (select case when c.stage in ('claimed', 'verified')
                                   and c.venue_id in (select o.venue_id from ours o)
                                  then 'ours' else c.stage end as stage,
                             count(distinct case when c.stage in ('claimed', 'verified')
                                                 then coalesce(c.venue_id, c.id) else c.id end) n
                        from public.space_contacts c
                       where not c.is_test
                         and not public.outreach_aside(c.topic, c.stage)
                         and (coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)
                       group by 1) x), '{}'::jsonb)
    || jsonb_build_object(
         '_wrote',    (select count(*) from public.space_contacts
                        where not is_test and not public.outreach_aside(topic, stage) and public.outreach_group(source) = 'wrote'),
         '_listed',   (select count(*) from public.space_contacts
                        where not is_test and not public.outreach_aside(topic, stage) and public.outreach_group(source) = 'listed'),
         '_prospect', (select count(*) from public.space_contacts
                        where not is_test and not public.outreach_aside(topic, stage) and public.outreach_group(source) = 'prospect'),
         '_no_email', (select count(*) from public.space_contacts
                        where not is_test and not public.outreach_aside(topic, stage) and email is null
                          and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)),
         '_aside',    (select count(*) from public.space_contacts c
                        where not c.is_test and public.outreach_aside(c.topic, c.stage)
                          and (coalesce(p_group, '') = '' or public.outreach_group(c.source) = p_group)),
         '_tests',    (select count(*) from public.space_contacts
                        where is_test
                          and (coalesce(p_group, '') = '' or public.outreach_group(source) = p_group)))
  end;
$$;
revoke all on function public.admin_outreach_counts(text) from public, anon;
grant execute on function public.admin_outreach_counts(text) to authenticated;

-- ============================================================
-- Migration 148: the path through Outreach, step by step.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Oct 2026: "I'm wanting to visualise the steps we're
-- taking or can take within this outreach section, to visualise next
-- possible steps. For example, outreach to potential candidates where
-- we don't have an email address, in addition spaces who have claimed,
-- and have accessed their members area, then to spaces who have
-- accessed their area, and used the account, how many times used, and
-- then steps to becoming verified."
--
-- Two halves, each a row of steps with how many spaces stand on it:
--   reaching them   no address yet, ready to write to, written to and
--                   waiting, follow-up due, replied, stepped off;
--   once claimed    claimed, signed in to their Owner account, used
--                   it, looked at Verified, on Verified.
--
-- What was missing: nothing recorded an owner opening their Owner
-- account. From this migration on, every opening is counted
-- (owner_visits). Before it there is only "signed in at least once"
-- and what they did there: changes saved and sent, questions
-- answered, ideas voted on, billing actions.
--
--   * owner_seen()               the Owner account says "opened"
--   * outreach_owner_activity()  one line per space with an owner
--   * admin_outreach_path()      the numbers for the picture
--   * admin_outreach_list()      gains p_step (the list for one step)
--                                and, for a claimed space, what its
--                                owner has done
-- ============================================================

-- ------------------------------------------------ the Owner account, opened
-- One row per space, owner and day; "opens" counts the openings that
-- day (a reload within half an hour is the same opening).
create table if not exists public.owner_visits (
  venue_id    uuid not null references public.venues(id) on delete cascade,
  owner_email text not null,
  day         date not null default current_date,
  opens       integer not null default 1,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  primary key (venue_id, owner_email, day)
);
alter table public.owner_visits enable row level security;
-- No policy: only the functions below read or write it.
revoke all on public.owner_visits from public, anon, authenticated;

insert into public.sync_settings (key, value)
values ('owner_visits_since', to_jsonb(current_date::text))
on conflict (key) do nothing;

create or replace function public.owner_seen()
returns void language plpgsql security definer set search_path = public as $$
declare em text := public.owner_email();
begin
  -- A founder looking at their own test space is not an owner's visit.
  if em is null or public.is_admin() then return; end if;
  insert into public.owner_visits (venue_id, owner_email, day)
  select v.id, em, current_date
    from public.venues v
   where lower(btrim(v.listing_owner_email)) = em
  on conflict (venue_id, owner_email, day) do update
     set opens = public.owner_visits.opens + 1, last_at = now()
   where public.owner_visits.last_at < now() - interval '30 minutes';
end $$;
revoke all on function public.owner_seen() from public, anon;
grant execute on function public.owner_seen() to authenticated;

-- ------------------------------------------------ what each owner has done
create or replace function public.outreach_owner_activity()
returns table (
  venue_id     uuid,
  owner_email  text,
  tier         text,
  signed_in_at timestamptz,   -- their last sign-in since they claimed
  opens        integer,       -- Owner account openings since counting began
  open_days    integer,
  last_open    timestamptz,
  edits        integer,       -- rounds of changes they started
  submitted    integer,       -- times they sent changes for review
  answers      integer,       -- questions answered
  ideas        integer,       -- ideas voted on or suggested
  billing      integer,       -- billing actions (card, cancel, resume)
  last_did     timestamptz,
  looked       boolean,       -- opened the Verified payment step, not paid
  checkout     boolean        -- got as far as Stripe's page
) language sql stable security definer set search_path = public as $$
  with o as (
    select v.id,
           nullif(lower(btrim(coalesce(v.listing_owner_email, ''))), '') as em,
           coalesce(v.listing_tier, 'free') as tier
      from public.venues v
     where btrim(coalesce(v.listing_owner_email, '')) <> ''
        or coalesce(v.listing_tier, 'free') = 'verified'
  )
  select o.id, o.em, o.tier,
         -- A sign-in from their claim on: an address that used the
         -- map long before claiming has not been in the Owner account.
         (select max(u.last_sign_in_at) from auth.users u
           where lower(btrim(u.email)) = o.em
             and u.last_sign_in_at >= coalesce(
                   (select min(k.created_at) from public.listing_claims k
                     where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em),
                   '-infinity'::timestamptz)),
         coalesce((select sum(w.opens) from public.owner_visits w
                    where w.venue_id = o.id and w.owner_email = o.em), 0)::integer,
         (select count(*) from public.owner_visits w
           where w.venue_id = o.id and w.owner_email = o.em)::integer,
         (select max(w.last_at) from public.owner_visits w
           where w.venue_id = o.id and w.owner_email = o.em),
         (select count(*) from public.owner_drafts d
           where d.venue_id = o.id and lower(d.owner_email) = o.em)::integer,
         (select count(*) from public.owner_draft_events e
           where e.venue_id = o.id and lower(e.owner_email) = o.em
             and e.status = 'submitted')::integer,
         (select count(*) from public.owner_answers a
           where a.venue_id = o.id and lower(a.owner_email) = o.em
             and not a.skipped)::integer,
         ((select count(*) from public.owner_idea_votes x
            where x.venue_id = o.id and lower(x.owner_email) = o.em)
          + (select count(*) from public.owner_idea_suggestions s
              where s.venue_id = o.id and lower(s.owner_email) = o.em))::integer,
         (select count(*) from public.owner_billing_events b
           where b.venue_id = o.id and lower(b.owner_email) = o.em)::integer,
         (select max(t) from (
            select max(d.created_at) as t from public.owner_drafts d
             where d.venue_id = o.id and lower(d.owner_email) = o.em
            union all
            select max(e.created_at) from public.owner_draft_events e
             where e.venue_id = o.id and lower(e.owner_email) = o.em and e.status = 'submitted'
            union all
            select max(a.created_at) from public.owner_answers a
             where a.venue_id = o.id and lower(a.owner_email) = o.em and not a.skipped
            union all
            select max(x.created_at) from public.owner_idea_votes x
             where x.venue_id = o.id and lower(x.owner_email) = o.em
            union all
            select max(s.created_at) from public.owner_idea_suggestions s
             where s.venue_id = o.id and lower(s.owner_email) = o.em
            union all
            select max(b.created_at) from public.owner_billing_events b
             where b.venue_id = o.id and lower(b.owner_email) = o.em) z),
         o.tier <> 'verified' and exists (
           select 1 from public.listing_claims k
            where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em
              and k.plan = 'verified' and k.status in ('started', 'abandoned')),
         o.tier <> 'verified' and exists (
           select 1 from public.listing_claims k
            where k.venue_id = o.id and lower(btrim(k.owner_email)) = o.em
              and k.plan = 'verified' and k.status in ('started', 'abandoned')
              and k.billing_period is not null)
    from o;
$$;
revoke all on function public.outreach_owner_activity() from public, anon, authenticated;
grant execute on function public.outreach_owner_activity() to service_role;

-- A follow-up that has come due and has not been sent (the same rule
-- as the number beside Outreach in the menu, migration 146).
create or replace function public.outreach_follow_up_due(
  p_stage text, p_follow date, p_last_out timestamptz)
returns boolean language sql stable as $$
  select p_follow is not null and p_follow <= current_date
     and (p_last_out is null or p_last_out::date < p_follow)
     and p_stage not in ('claimed', 'verified', 'declined', 'unsubscribed', 'bounced');
$$;

-- ------------------------------------------------ the numbers for the picture
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
    from public.space_contacts c;

  select jsonb_build_object(
           'claimed',     count(*),
           'not_opened',  count(*) filter (where not x.accessed),
           'opened',      count(*) filter (where x.accessed),
           'opened_only', count(*) filter (where x.accessed and x.did = 0),
           'used',        count(*) filter (where x.did > 0),
           'looked',      count(*) filter (where x.looked),
           'verified',    count(*) filter (where x.tier = 'verified'))
    into own
    from (select a.*,
                 (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
                 (a.signed_in_at is not null or a.opens > 0
                  or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
            from public.outreach_owner_activity() a) x;

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
    'visits_since', (select s.value #>> '{}' from public.sync_settings s
                      where s.key = 'owner_visits_since'));
end $$;
revoke all on function public.admin_outreach_path() from public, anon;
grant execute on function public.admin_outreach_path() to authenticated;

-- ------------------------------------------------ the list, for one step too
-- As migration 124, plus: p_step (one step of the path; the stage and
-- the group are then left aside) and "owner" on a claimed space.
drop function if exists public.admin_outreach_list(text, text, integer, text);
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
      select a.*,
             (greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing) as did,
             (a.signed_in_at is not null or a.opens > 0
              or greatest(a.edits, a.submitted) + a.answers + a.ideas + a.billing > 0) as accessed
        from public.outreach_owner_activity() a
    )
    select jsonb_agg(row_to_json(x)::jsonb order by x.no_email, x.sort_at desc)
      from (
        select c.id, c.venue_id, c.space_name, c.kind, c.city, c.country,
               c.person_name, c.email, c.phone, c.website, c.instagram,
               c.source, c.form_name, c.stage, c.stage_at, c.first_in_at,
               c.last_in_at, c.last_out_at, c.follow_up_on, c.notes,
               c.unsubscribed_at,
               (c.email is null) as no_email,
               greatest(coalesce(c.last_in_at, c.created_at), coalesce(c.last_out_at, c.created_at), c.stage_at) as sort_at,
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
                 'last_did', a.last_did, 'looked', a.looked, 'checkout', a.checkout) end as owner
          from public.space_contacts c
          left join public.venues v on v.id = c.venue_id
          left join act a on a.venue_id = c.venue_id and c.stage in ('claimed', 'verified')
         where (st <> '' or p_stage is null or p_stage = '' or c.stage = p_stage)
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
                  when 'claimed'     then a.venue_id is not null
                  when 'not_opened'  then a.venue_id is not null and not a.accessed
                  when 'opened'      then coalesce(a.accessed, false)
                  when 'opened_only' then coalesce(a.accessed and a.did = 0, false)
                  when 'used'        then coalesce(a.did > 0, false)
                  when 'looked'      then coalesce(a.looked, false)
                  when 'verified'    then coalesce(a.tier = 'verified', false)
                  else false end)
         order by no_email, sort_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_outreach_list(text, text, integer, text, text) from public, anon;
grant execute on function public.admin_outreach_list(text, text, integer, text, text) to authenticated;

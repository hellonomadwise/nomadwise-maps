-- ============================================================
-- Migration 221: saying hello to the spaces we put on nomadwise.io.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 25 Oct 2026: "once I've created a listing on nomadwise,
-- that a space hasn't done themselves, there can be a flow where we can
-- easily reach out to them, to say hey, we've added you to
-- nomadwise.io, feel free to take a look at your profile, and you can
-- claim and manage your account for free. maybe not even mention the
-- paid plan at that stage." And for spaces with no email: fine "so
-- long as we can track communication and ideally the message sent".
--
--   * invite_new_page (the email hello) is kept as it is, with its one
--     soft line about Nomadwise Plus ("if you don't ask you don't get,
--     but subtle, soft and friendly: awareness, soft sell").
--   * invite_new_page_wa: the same hello, short, for WhatsApp,
--     Instagram or Facebook. Sent by hand from the phone; "I sent it"
--     records the words on the space's card, as the other WhatsApp
--     messages do.
--   * admin_next_up: a "new_page" part, the pages put live in the last
--     60 days whose space has not heard from us yet, newest first.
-- Nothing is sent by itself. Pure ASCII. Safe to apply twice.
-- ============================================================

insert into public.outreach_templates (key, name, subject, body, stream, sort)
values ('invite_new_page_wa', 'WhatsApp: hello to a new page of ours', 'WhatsApp',
'Hi, this is Jonathan from Nomadwise. We have added {space} to nomadwise.io, where remote workers and digital nomads look for places to work from: {page_link}

Being listed is free. If you would like to make the page your own, you can claim it at no cost and update your opening hours, photos, description and prices: {claim_link}

If you ever want a little extra visibility, there is also an optional Nomadwise Plus plan, with the details in your Owner account.

{signoff}', 'outbound', 46)
on conflict (key) do nothing;

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

  -- A page we put live in the last 60 days whose space has not heard
  -- from us yet (migration 221): say hello, by email, or WhatsApp when
  -- there is no address. The newest first.
  begin
    select jsonb_build_object(
             'n', count(*),
             'with_email', count(*) filter (where coalesce(c.email, '') <> ''),
             'name', (array_agg(v.name order by v.new_page_live_at desc))[1],
             'at', max(v.new_page_live_at))
      into part
      from public.venues v
      join public.space_contacts c on c.venue_id = v.id
     where v.new_page_live_at > now() - interval '60 days'
       and not c.is_test
       and not public.outreach_aside(c.topic, c.stage)
       and c.stage = 'new'
       and c.last_out_at is null
       and c.last_in_at is null
       and btrim(coalesce(v.listing_owner_email, '')) = '';
    out := out || jsonb_build_object('new_page', part);
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

notify pgrst, 'reload schema';

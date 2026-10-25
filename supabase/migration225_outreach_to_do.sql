-- migration225_outreach_to_do.sql
-- Outreach as To do / Waiting / Done (Jonathan, 25 Oct 2026: "I'm
-- really wanting to simplify so i can understand clearly what action
-- to take").
--
-- "Not now" said nothing about why. A line now leaves the work lists
-- with a reason, and the reason decides where it goes:
--   unreachable  no email, WhatsApp or Instagram found  -> Not now
--   not_fit      closed, a chain's head office, a duplicate page,
--                or other (the detail)                  -> Not now, and
--                                                          "Not for outreach"
--   said_no      they said no                            -> Declined
-- "Already in touch on another line" joins the two lines instead
-- (admin_outreach_join, below).
-- Nothing is ever sent by any of this.
--
-- Pure ASCII. Safe to run twice.

alter table public.space_contacts
  add column if not exists aside_reason text,
  add column if not exists aside_detail text,
  add column if not exists aside_at timestamptz,
  -- the topic it had, kept while "Not a fit" stands in for it
  add column if not exists aside_topic text;

-- Put a line aside with a reason, or (p_reason null) bring it back to
-- where it was: New when nothing was ever sent either way, Replied when
-- they wrote last, otherwise Contacted.
create or replace function public.admin_outreach_set_aside(
  p_id uuid, p_reason text, p_detail text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  c     public.space_contacts%rowtype;
  label text;
  det   text := nullif(left(trim(coalesce(p_detail, '')), 200), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then
    raise exception 'This line is no longer in Outreach.';
  end if;
  if c.stage in ('claimed', 'verified') then
    raise exception 'This space has claimed its page, so it stays where it is.';
  end if;

  if p_reason is null then
    update public.space_contacts x set
      stage = case
                when x.stage = 'unsubscribed' then x.stage
                when x.last_in_at is not null
                     and (x.last_out_at is null or x.last_in_at > x.last_out_at) then 'replied'
                when x.last_out_at is not null then 'contacted'
                else 'new' end,
      topic = case when x.topic = 'not_a_fit' then x.aside_topic else x.topic end,
      aside_reason = null, aside_detail = null, aside_at = null, aside_topic = null,
      notes = nullif(concat_ws(E'\n', nullif(x.notes, ''),
                'Brought back ' || to_char(now() at time zone 'utc', 'YYYY-MM-DD') || '.'), '')
    where x.id = p_id;
    return;
  end if;

  if p_reason not in ('unreachable', 'not_fit', 'said_no') then
    raise exception 'Unknown reason: %', p_reason;
  end if;
  if c.stage = 'unsubscribed' then
    raise exception 'They unsubscribed, so this line is already out of the lists.';
  end if;
  label := case p_reason
             when 'unreachable' then 'No way to reach them'
             when 'not_fit'     then 'Not a fit'
             else 'They said no' end;

  update public.space_contacts x set
    stage = case when p_reason = 'said_no' then 'declined' else 'not_now' end,
    topic = case when p_reason = 'not_fit' then 'not_a_fit' else x.topic end,
    -- the topic before "Not a fit", for Bring back (kept from the first
    -- time it was set aside)
    aside_topic = case when x.topic = 'not_a_fit' then x.aside_topic else x.topic end,
    aside_reason = p_reason,
    aside_detail = det,
    aside_at = now(),
    notes = nullif(concat_ws(E'\n', nullif(x.notes, ''),
              label || coalesce(' (' || det || ')', '') || ', '
              || to_char(now() at time zone 'utc', 'YYYY-MM-DD') || '.'), '')
  where x.id = p_id;
end $$;
revoke all on function public.admin_outreach_set_aside(uuid, text, text) from public, anon;
grant execute on function public.admin_outreach_set_aside(uuid, text, text) to authenticated;

-- Why each line was put aside, by line id: {reason, detail, at}.
create or replace function public.admin_outreach_asides()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_object_agg(c.id::text, jsonb_build_object(
             'reason', c.aside_reason, 'detail', c.aside_detail, 'at', c.aside_at))
      from public.space_contacts c
     where c.aside_reason is not null), '{}'::jsonb);
end $$;
revoke all on function public.admin_outreach_asides() from public, anon;
grant execute on function public.admin_outreach_asides() to authenticated;

-- Two lines for one space (Jobetter, 25 Oct 2026: the new page's line,
-- and an older line that already had the address): p_drop is joined
-- into p_keep with everything it holds (outreach_merge, migration 171).
-- Refused when the two are different spaces on the map.
create or replace function public.admin_outreach_join(p_keep uuid, p_drop uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  k public.space_contacts%rowtype;
  d public.space_contacts%rowtype;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_keep is null or p_drop is null or p_keep = p_drop then
    raise exception 'Pick another line to join this one with.';
  end if;
  select * into k from public.space_contacts where id = p_keep;
  if not found then raise exception 'That line is no longer in Outreach.'; end if;
  select * into d from public.space_contacts where id = p_drop;
  if not found then raise exception 'This line is no longer in Outreach.'; end if;
  if k.venue_id is not null and d.venue_id is not null and k.venue_id <> d.venue_id then
    raise exception using message =
      coalesce(k.space_name, 'That line') || ' and ' || coalesce(d.space_name, 'this line')
      || ' are two different spaces on the map, so they were not joined.';
  end if;
  if not public.outreach_merge(p_keep, p_drop) then
    raise exception 'The two lines could not be joined. Nothing changed.';
  end if;
end $$;
revoke all on function public.admin_outreach_join(uuid, uuid) from public, anon;
grant execute on function public.admin_outreach_join(uuid, uuid) to authenticated;

-- Messages that go through a Claude chat are written on the space's
-- Outreach line, and a space we are in touch with gets no sequence
-- emails for a while (Jonathan, 23 Nov 2026, after "Your first request
-- for Madeira Friends Hub" went to Luís the morning after the two of
-- them had already settled that request on WhatsApp: "this email should
-- not have been sent ... for future, any comms that comes through
-- claude, should be updated within nomadmaps, so it stops any sequence
-- emails").
--
-- 1. log_space_message(): one call from a session writes a message (in
--    or out; WhatsApp, email, Instagram, Facebook, phone, contact form)
--    on the space's Outreach line, as the buttons in Outreach do. Not
--    for the app: only the database owner may call it.
-- 2. space_in_touch(): true when the space wrote to us, or a message of
--    ours was logged through a Claude chat, in the last 14 days.
-- 3. The tips (first request, page complete, next thing, gone quiet) and
--    the sign-in reminders leave such a space alone. A reminder is held
--    and goes once the 14 days are over; a first-request tip is let go,
--    as its week will have passed.
create or replace function public.log_space_message(
  p_venue uuid, p_direction text, p_channel text, p_body text,
  p_at timestamptz default now(), p_by text default 'Jonathan, via Claude')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c     public.space_contacts%rowtype;
  label text := case lower(coalesce(p_channel, ''))
                  when 'whatsapp' then 'WhatsApp'
                  when 'email' then 'Email'
                  when 'instagram' then 'Instagram'
                  when 'facebook' then 'Facebook'
                  when 'phone' then 'Phone call'
                  when 'form' then 'Contact form'
                end;
  t     timestamptz := least(now(), coalesce(p_at, now()));
begin
  if p_direction is null or p_direction not in ('in', 'out') then
    raise exception 'Direction must be in or out.';
  end if;
  if label is null then
    raise exception 'Unknown channel: %', coalesce(p_channel, '(none)');
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'Say what was said.';
  end if;
  select * into c from public.space_contacts
   where venue_id = p_venue and not coalesce(is_test, false)
   order by updated_at desc nulls last
   limit 1
   for update;
  if not found then
    raise exception 'No Outreach line for this space.';
  end if;
  insert into public.outreach_messages (contact_id, direction, subject, body, sent_by, at)
  values (c.id, p_direction, label, left(btrim(p_body), 4000),
          case when p_direction = 'out'
               then coalesce(nullif(btrim(coalesce(p_by, '')), ''), 'Jonathan, via Claude')
                    || ' (' || label || ')'
               else 'logged via Claude (' || label || ')' end,
          t);
  if p_direction = 'out' then
    update public.space_contacts
       set last_out_at = greatest(coalesce(last_out_at, t), t),
           stage = case when stage in ('new', 'contacted', 'not_now', 'replied')
                        then 'contacted' else stage end
     where id = c.id;
  else
    update public.space_contacts
       set last_in_at = greatest(coalesce(last_in_at, t), t),
           first_in_at = coalesce(first_in_at, t),
           stage = case when stage in ('contacted', 'not_now') then 'replied' else stage end
     where id = c.id;
  end if;
  return jsonb_build_object('ok', true, 'contact', c.id, 'at', t);
end $function$;

revoke all on function public.log_space_message(uuid, text, text, text, timestamptz, text)
  from public, anon, authenticated;

create or replace function public.space_in_touch(p_venue uuid, p_days integer default 14)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from public.outreach_messages m
      join public.space_contacts c on c.id = m.contact_id
     where c.venue_id = p_venue
       and m.at > now() - make_interval(days => p_days)
       and (m.direction = 'in' or m.sent_by like '%via Claude%'));
$function$;

select public.pm_patch_fn('public.owner_tips_due()',
  '    parts := public.page_parts(r.id);',
  E'    -- In touch with them in person lately: no tips (migration 348).\n    if public.space_in_touch(r.id) then\n      continue;\n    end if;\n    parts := public.page_parts(r.id);',
  'space_in_touch');
select public.pm_patch_fn('public.signin_reminders_run()',
  '      insert into public.sequence_sends (sequence_key, step, venue_id, owner_email)',
  E'      -- In touch with them in person lately: held (migration 348).\n      if public.space_in_touch(r.venue_id) then\n        continue;\n      end if;\n      insert into public.sequence_sends (sequence_key, step, venue_id, owner_email)',
  'space_in_touch');

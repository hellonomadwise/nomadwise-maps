-- ============================================================
-- Migration 244: everyone who enquires hears from us straight away.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026: "i would kind of expect to receive a
-- confirmation email sent to user who enquired, to confirm the
-- information they submitted, and to let them know what is happening."
--
-- Before: the person who enquired was only emailed once the enquiry
-- had actually gone to the space (free enquiries, Premium with the
-- owner's address, or when a founder passed it on). An enquiry that
-- waited for a founder, was held for Premium, or went to a Verified
-- space's own enquiry address got no email at all, and none of the
-- emails showed what they had sent.
--
-- Now, the moment the enquiry is filed:
--   * sent to the space (any route): "Your enquiry has been sent to X",
--     with what they sent and their details;
--   * waiting for a founder or held: "We have your enquiry for X",
--     with what they sent, and that we email again when it is with
--     them (the existing "sent" email follows when it goes);
--   * our own tests (an @nomadwise.io address): never go to the space
--     or use one of its free enquiries; the email the person would have
--     had comes to the tester, marked [Test].
--
-- And enquiry_nudge(): the page asks for the enquiry import to run as
-- soon as the form is sent (GitHub's ten-minute schedule in practice
-- runs every few hours), so the email arrives within a few minutes.
-- ============================================================

alter table public.enquiries add column if not exists nomad_ack_at timestamptz;

-- What they sent, as it goes in their emails.
create or replace function public.enquiry_what_you_sent(p_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  e   public.enquiries%rowtype;
  msg text;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null then return ''; end if;
  msg := btrim(regexp_replace(coalesce(e.message, ''),
                              '\s*\(Sent from the price list on the page\.\)\s*$', ''));
  return 'What you sent:' || E'\n'
      || coalesce(nullif(msg, ''), '(No message)') || E'\n\n'
      || 'Your details:' || E'\n'
      || 'Name: ' || e.name || E'\n'
      || 'Email: ' || e.email
      || coalesce(E'\n' || 'Phone: ' || nullif(btrim(coalesce(e.phone, '')), ''), '');
end $$;

-- "Your enquiry has been sent to X": now with what they sent (one
-- enquiry; the several-spaces email from Pass on stays as it was).
create or replace function public.enquiry_nomad_email(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  em    text;
  nm    text;
  first text;
  n     integer;
  one   text;
  site  text;
  lines text;
  sites boolean;
begin
  select lower(min(e.email)), min(e.name), count(*), min(v.name), min(v.website),
         string_agg('- ' || v.name
                    || coalesce(' (' || nullif(btrim(coalesce(v.website, '')), '') || ')', ''),
                    E'\n' order by v.name),
         bool_or(coalesce(btrim(v.website), '') <> '')
    into em, nm, n, one, site, lines, sites
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
   where e.id = any(p_ids);
  if coalesce(n, 0) = 0 then return null; end if;
  first := nullif(nullif(split_part(btrim(nm), ' ', 1), ''), 'Someone');

  if n = 1 then
    return jsonb_build_object(
      'to', em,
      'subject', 'Your enquiry has been sent to ' || one,
      'body',
        'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
        || 'Thank you for your enquiry on Nomadwise. We have sent it to ' || one
        || ', and their reply will come straight to your email address.' || E'\n\n'
        || public.enquiry_what_you_sent(p_ids[1]) || E'\n\n'
        || case when coalesce(btrim(site), '') <> ''
                then 'If you would like to contact them yourself as well, their website is '
                     || btrim(site) || E'\n\n'
                else '' end
        || 'If you have any further questions, simply reply to this email.' || E'\n\n'
        || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
  end if;

  return jsonb_build_object(
    'to', em,
    'subject', 'Your enquiry has been sent to ' || n || ' spaces',
    'body',
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thank you for your enquiry on Nomadwise. We have sent it to these '
      || n || ' spaces:' || E'\n\n'
      || lines || E'\n\n'
      || 'Their replies will come straight to your email address.'
      || case when sites
              then ' If you would like to contact any of them yourself, their websites '
                   || 'are listed above.'
              else '' end || E'\n\n'
      || 'If you have any further questions, simply reply to this email.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;

-- "We have your enquiry for X": waiting for a founder, or held.
create or replace function public.enquiry_received_email(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  vname text;
  first text;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null then return null; end if;
  select name into vname from public.venues where id = e.venue_id;
  first := nullif(nullif(split_part(btrim(e.name), ' ', 1), ''), 'Someone');
  return jsonb_build_object(
    'to', lower(e.email),
    'subject', 'We have your enquiry' || coalesce(' for ' || vname, ''),
    'body',
      'Hi ' || coalesce(first, 'there') || ',' || E'\n\n'
      || 'Thank you for your enquiry on Nomadwise. We have received it and will pass it on to '
      || coalesce(vname, 'the space') || '. We will email you again as soon as it is with them, '
      || 'and their reply will come straight to your email address.' || E'\n\n'
      || public.enquiry_what_you_sent(p_id) || E'\n\n'
      || 'If anything needs changing, or you would like to add something, simply reply to this email.'
      || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise');
end $$;

-- Sends one of the two to the person who enquired. Never in the way of
-- filing the enquiry.
create or replace function public.enquiry_tell_nomad_now(p_id uuid, p_sent boolean, p_test text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  e    public.enquiries%rowtype;
  mail jsonb;
begin
  select * into e from public.enquiries where id = p_id;
  if e.id is null then return; end if;
  mail := case when p_sent and e.venue_id is not null
               then public.enquiry_nomad_email(array[p_id])
               else public.enquiry_received_email(p_id) end;
  if mail is null then return; end if;
  perform public.send_enquiry_mail(
    lower(e.email), 'spaces@nomadwise.io',
    coalesce(p_test, '') || (mail ->> 'subject'), mail ->> 'body',
    case when p_test is not null then 'enquiry_test_nomad'
         when p_sent then 'enquiry_passed_nomad'
         else 'enquiry_received_nomad' end,
    p_id::text, e.venue_id, null);
  update public.enquiries
     set nomad_ack_at = now(),
         nomad_emailed_at = case when p_sent and p_test is null then now() else nomad_emailed_at end
   where id = p_id;
exception when others then
  null;
end $$;
revoke all on function public.enquiry_tell_nomad_now(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.enquiry_what_you_sent(uuid) from public, anon, authenticated;
revoke all on function public.enquiry_received_email(uuid) from public, anon, authenticated;

-- Filing a new enquiry: as before, plus the email to the person who
-- enquired, and team tests kept away from the space.
create or replace function public.enquiry_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  vname text;
  route text;
  dest  text;
  n     int;
  lim   int;
  mail  jsonb;
begin
  if new.status <> 'new' then
    return new;           -- history, or filed by hand
  end if;
  select name into vname from public.venues where id = new.venue_id;

  -- Our own test enquiries (an @nomadwise.io address) never reach the
  -- space or use one of its free enquiries. The tester gets the email
  -- the person would have had, marked [Test].
  if lower(coalesce(new.email, '')) like '%@nomadwise.io' then
    update public.enquiries
       set status = 'closed',
           handled_note = 'Team test (nomadwise.io address), not sent to the space.'
     where id = new.id;
    begin
      route := public.enquiry_route(new.venue_id);
    exception when others then
      route := 'waiting';
    end;
    perform public.enquiry_tell_nomad_now(
      new.id, route in ('free', 'direct'),
      '[Test, not sent to ' || coalesce(vname, 'the space') || '] ');
    return new;
  end if;

  begin
    route := public.enquiry_route(new.venue_id);
  exception when others then
    route := 'waiting';   -- never lost: a founder passes it on
  end;

  if route = 'free' then
    begin
      update public.enquiries set free_slot = true where id = new.id;
      -- (enquiry_send_to_space tells the person it went.)
      dest := public.enquiry_send_to_space(new.id, 'enquiry_free');
      n := public.free_enquiries_used(new.venue_id);
      lim := (public.free_enquiry_rule() ->> 'limit')::int;
      perform public.notify_phone(
        'Free enquiry ' || n || ' of ' || lim || ' sent to ' || coalesce(vname, 'a space'),
        new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
        'envelope');
      return new;
    exception when others then
      -- Could not be sent: it waits for a founder instead (the free
      -- place is given back, as the block is undone).
      route := 'waiting';
    end;
  end if;

  if route = 'held' then
    update public.enquiries set status = 'held', held_at = now() where id = new.id;
    begin
      mail := public.enquiry_held_email(new.id);
      perform public.send_owner_email(
        mail ->> 'to', mail ->> 'subject', mail ->> 'body',
        'enquiry_held', new.id::text,
        'Get Premium', 'https://nomadmaps.io/?owner&billing');
    exception when others then
      null;               -- still held; the founders are told below
    end;
    perform public.enquiry_tell_nomad_now(new.id, false);
    perform public.notify_phone(
      'Enquiry held for Premium: ' || coalesce(vname, 'a space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120)
        || E'\nTheir free enquiries are used. Move it to pass on if you want it to go.',
      'envelope');
    return new;
  end if;

  if route = 'direct' and coalesce(public.enquiry_goes_direct(new.venue_id), false) then
    perform public.send_enquiry(new.id);
    if (select status from public.enquiries where id = new.id) = 'sent' then
      perform public.enquiry_tell_nomad_now(new.id, true);
    end if;
    perform public.notify_phone(
      'Enquiry sent to ' || coalesce(vname, 'a Verified space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
      'envelope');
  elsif route = 'direct' then
    -- Premium with only the owner's email (switch on).
    begin
      dest := public.enquiry_send_to_space(new.id, 'enquiry');
      perform public.notify_phone(
        'Enquiry sent to ' || coalesce(vname, 'a Premium space'),
        new.name || ' wrote: ' || left(coalesce(new.message, ''), 120),
        'envelope');
      return new;
    exception when others then
      route := 'waiting';
    end;
  end if;

  if route = 'waiting' then
    update public.enquiries set status = 'waiting' where id = new.id;
    perform public.enquiry_tell_nomad_now(new.id, false);
    perform public.notify_phone(
      'Enquiry to pass on: ' || coalesce(vname, new.listing_text, 'a space'),
      new.name || ' wrote: ' || left(coalesce(new.message, ''), 120)
        || E'\nOpen the control centre to pass it on.',
      'envelope');
  end if;
  return new;
exception when others then
  return new;
end $$;

-- The page asks for the enquiry import to run now (at most once a
-- minute; anyone can ask, it only starts the usual run).
create or replace function public.enquiry_nudge()
returns void language plpgsql security definer set search_path = public as $$
declare
  tok  text;
  last timestamptz;
begin
  insert into public.sync_settings (key, value, updated_at)
  values ('enquiry_nudge', '{}'::jsonb, now() - interval '1 day')
  on conflict (key) do nothing;
  select updated_at into last from public.sync_settings where key = 'enquiry_nudge' for update;
  if last > now() - interval '60 seconds' then
    return;
  end if;
  select decrypted_secret into tok
    from vault.decrypted_secrets where name = 'github_actions_token' limit 1;
  if coalesce(tok, '') = '' then
    return;
  end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/webflow_push.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || tok,
      'Accept', 'application/vnd.github+json',
      'Content-Type', 'application/json',
      'User-Agent', 'nomadmaps-db',
      'X-GitHub-Api-Version', '2022-11-28'));
  update public.sync_settings
     set value = jsonb_build_object('at', now()), updated_at = now()
   where key = 'enquiry_nudge';
exception when others then
  null;
end $$;
revoke all on function public.enquiry_nudge() from public;
grant execute on function public.enquiry_nudge() to anon, authenticated;

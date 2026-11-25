-- Migration 363: Claude reads each space's own website before Jonathan
-- approves its page, and learns from what he then decides.
--
-- Jonathan, 25 Nov 2026, on the Ready to approve cards: "is there a way
-- to not have to look at their website, if you can do this for me. I'm
-- ideally wanting to move to you being able to learn from me and also
-- then move through these space listings with minimal error".
--
-- What changes:
--   * listing_checks: one row per check. Claude searches the web for
--     the space, reads up to two pages of its own website and answers:
--     list it / look yourself / not coworking / closed, what it is, what
--     a laptop worker can buy there, prices seen, the website address,
--     and anything to watch out for.
--   * listing_check_auto() runs every two minutes: it collects answers
--     that have come back, then checks up to three spaces in Ready to
--     approve that have no check yet (a failed one is tried again after
--     30 minutes, three times at most). At most 120 checks a day.
--   * listing_judgements: what Jonathan decided on each space (approved,
--     not for the site with his reason, or sent back to New spaces), and
--     what the check had said. Written by a trigger on venues, so the
--     buttons in the app need no change for it. Seeded with the spaces
--     already marked not for the site.
--   * "Claude got this wrong" on the card: his correction in a few words,
--     kept as a lesson.
--   * Every new check is given the audience line, his corrections and
--     the decisions where he went against the check, newest first. That
--     is how it learns from him.
--   * admin_listing_checks_latest() gives the app the newest check for
--     each space in Ready to approve, and which are still waiting.
--   * Off switch: sync_settings 'listing_check_auto' {"on": false}.
--
-- Cost: about 10 to 25 US cents a check (web searches, the pages read,
-- Claude's answer). The 76 waiting today: roughly 10 to 20 dollars, once.

create table if not exists public.listing_checks (
  id          bigserial primary key,
  venue_id    uuid not null references public.venues(id) on delete cascade,
  asked_at    timestamptz not null default now(),
  request_id  bigint,
  answer      jsonb,
  error       text,
  done_at     timestamptz,
  usage       jsonb,
  said        text,
  feedback    text,
  feedback_at timestamptz
);
create index if not exists listing_checks_venue on public.listing_checks (venue_id, asked_at desc);
alter table public.listing_checks enable row level security;

create table if not exists public.listing_judgements (
  id            bigserial primary key,
  venue_id      uuid references public.venues(id) on delete set null,
  name          text,
  city          text,
  country       text,
  decision      text not null,   -- approved | not_for_site | sent_back | correction
  reason        text,
  note          text,
  check_verdict text,
  check_said    text,
  decided_at    timestamptz not null default now()
);
create index if not exists listing_judgements_at on public.listing_judgements (decided_at desc);
alter table public.listing_judgements enable row level security;

insert into public.sync_settings (key, value)
-- Starts off: switched on by hand once the first five checks have been
-- read (25 Nov 2026).
values ('listing_check_auto', '{"on": false}'::jsonb)
on conflict (key) do nothing;

-- Spaces already marked not for the site: the first lessons.
insert into public.listing_judgements (venue_id, name, city, country, decision, reason, note, decided_at)
select x.id, x.name, x.city, x.country, 'not_for_site', x.website_dismiss_reason,
       x.website_dismiss_note, x.website_dismissed_at
  from public.venues x
 where x.website_dismissed_at is not null
   and x.type = 'coworking'
   and not exists (select 1 from public.listing_judgements j where j.venue_id = x.id);

-- ------------------------------------------------ the question
create or replace function public.listing_check_ask(p_venue uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  k       text;
  model   text;
  v       record;
  lessons text;
  prompt  text;
  req     bigint;
  cid     bigint;
  types   text;
  site    text;
begin
  if not (coalesce(public.is_admin(), false)
          or current_setting('nomadwise.auto_check', true) = '1') then
    raise exception 'founders only';
  end if;
  select decrypted_secret into k
    from vault.decrypted_secrets where name = 'anthropic_api_key' limit 1;
  if nullif(btrim(coalesce(k, '')), '') is null then
    raise exception 'No Claude key in the Supabase Vault yet (anthropic_api_key).';
  end if;
  select nullif(btrim(decrypted_secret), '') into model
    from vault.decrypted_secrets where name = 'anthropic_model' limit 1;
  model := coalesce(model, 'claude-sonnet-4-5');
  if (select count(*) from public.listing_checks
       where asked_at > now() - interval '1 day') >= 120 then
    raise exception '120 website checks today already. More tomorrow.';
  end if;

  select x.* into v from public.venues x where x.id = p_venue;
  if v.id is null then
    raise exception 'No such space.';
  end if;

  select string_agg(t, ', ') into types
    from jsonb_array_elements_text(coalesce(v.g_details -> 'types', '[]'::jsonb)) t
   where t not in ('point_of_interest', 'establishment', 'service');
  site := coalesce(nullif(v.website, ''), nullif(v.website_prepared ->> 'website', ''));

  -- His lessons: corrections first, then decisions that went against
  -- the check, then not-for-the-site reasons. Newest first, 30 at most.
  select string_agg(line, E'\n') into lessons from (
    select '- ' || coalesce(j.name, 'A space') || coalesce(' (' || j.city || ')', '') || ': ' ||
           case j.decision
             when 'correction' then 'Jonathan corrected the check'
                                  || coalesce(' (it had said ' || j.check_verdict || ')', '')
                                  || ': "' || j.note || '"'
             when 'approved' then 'Jonathan approved it although the check said '
                                  || coalesce(j.check_verdict, '?')
                                  || coalesce(' ("' || j.check_said || '")', '')
             when 'not_for_site' then 'Jonathan said not for the site: ' || coalesce(j.reason, '')
                                  || coalesce('. "' || j.note || '"', '')
                                  || coalesce(' (the check had said ' || j.check_verdict || ')', '')
             else 'Jonathan sent it back to edit' || coalesce(': "' || j.note || '"', '')
           end as line
      from public.listing_judgements j
     where j.decision = 'correction'
        or (j.decision = 'approved' and j.check_verdict is not null and j.check_verdict <> 'list')
        or j.decision = 'not_for_site'
     order by (j.decision = 'correction') desc, j.decided_at desc
     limit 30) s;

  prompt := concat_ws(E'\n',
    'You check one coworking space for Nomadwise before Jonathan, the founder, approves its page on nomadwise.io. He does not want to open the space''s website himself, so your answer must be right. When unsure, say so: a wrong "list" costs more than a "check".',
    '',
    'The space:',
    '- Name: ' || v.name,
    '- Place: ' || concat_ws(', ', nullif(v.neighbourhood, ''), nullif(v.city, ''), nullif(v.country, ''),
                             nullif(v.g_details ->> 'shortFormattedAddress', '')),
    '- Google types: ' || coalesce(types, 'unknown'),
    '- Google rating: ' || coalesce(v.google_rating_snapshot::text, '?') || ' from ' || coalesce(v.google_reviews_snapshot::text, '?') || ' reviews',
    '- Google status: ' || coalesce(v.business_status, 'unknown'),
    '- Website we hold: ' || coalesce(site, 'none, find it'),
    '',
    'Who Nomadwise lists (Jonathan''s rule): places a remote worker could walk into, and everything those places sell. Not office buildings.',
    '- In: coworking spaces with day passes, hot desks, monthly desks, private offices by the month, meeting rooms. Stays of a day up to about six months. Chains are in where the branch has real coworking.',
    '- Out: office-only buildings or serviced offices with no desks or passes a visitor can buy; conventional leases; coworking for one trade only (therapists, beauty, hair, labs, music or podcast studios) that a laptop worker cannot use; coliving or hostels whose workspace is for guests only; members'' clubs that sell no access to non-members; places that have closed.',
    '- Cafes are not judged here: this is a coworking listing.',
    '',
    'Jonathan''s past decisions. Follow them; where one conflicts with the rule above, his decision wins:',
    coalesce(lessons, '- None yet.'),
    '',
    'How to check:',
    '1. Search for the space''s own website (the operator''s site, not a directory). For a chain, find this branch''s own page.',
    '2. Read at most two pages of it: the branch or home page, and the page with passes, memberships or prices.',
    '3. Other sites (directories, reviews, news) may only help you judge whether it is open or what it is. Never take prices from them.',
    '4. Check the address on the website matches the place above.',
    '',
    'After your research, end with exactly one JSON block in ```json fences:',
    '{"verdict": "list" or "check" or "not_coworking" or "closed",',
    ' "confidence": "high" or "medium" or "low",',
    ' "what_it_is": "one short sentence, plain British English",',
    ' "can_buy": ["day pass", "hot desk by the month", "private office", "meeting room", ...] (only what its own site shows),',
    ' "prices": "short, from its own site only, e.g. Day pass EUR 25, or empty",',
    ' "website": "https://... the page you relied on, or null",',
    ' "same_place": "yes" or "no" or "unclear",',
    ' "reason": "one or two short sentences why",',
    ' "watch_out": "one short sentence if Jonathan should look himself, else empty"}',
    'verdict "list": clearly in under the rule, open, and its own site confirms it. "check": anything unclear, its own site not found or not readable, the address does not match, or only other sites say it. "not_coworking": out under the rule. "closed": closed or closing.',
    'Write without dashes as punctuation.');

  insert into public.listing_checks (venue_id) values (p_venue) returning id into cid;

  select net.http_post(
    url := 'https://api.anthropic.com/v1/messages',
    body := jsonb_build_object(
      'model', model,
      'max_tokens', 1500,
      'tools', jsonb_build_array(
        jsonb_build_object('type', 'web_search_20250305', 'name', 'web_search', 'max_uses', 3),
        jsonb_build_object('type', 'web_fetch_20250910', 'name', 'web_fetch', 'max_uses', 2,
                           'max_content_tokens', 6000)),
      'messages', jsonb_build_array(
        jsonb_build_object('role', 'user', 'content', prompt))),
    headers := jsonb_build_object(
      'x-api-key', k,
      'anthropic-version', '2023-06-01',
      'anthropic-beta', 'web-fetch-2025-09-10',
      'content-type', 'application/json'),
    timeout_milliseconds := 150000)
  into req;

  update public.listing_checks set request_id = req where id = cid;
  return cid;
end $$;
revoke all on function public.listing_check_ask(uuid) from public, anon;
grant execute on function public.listing_check_ask(uuid) to authenticated;

-- ------------------------------------------------ the answer
create or replace function public.listing_check_collect(p_check bigint)
returns text language plpgsql security definer set search_path = public as $$
declare
  c      record;
  resp   record;
  body   jsonb;
  txt    text;
  part   text;
  parts  text[];
  parsed jsonb;
  msg    text;
begin
  select * into c from public.listing_checks where id = p_check;
  if c.id is null or c.done_at is not null then
    return 'done';
  end if;
  select r.status_code, r.content, r.timed_out into resp
    from net._http_response r where r.id = c.request_id;
  if not found then
    if c.asked_at > now() - interval '4 minutes' then
      return 'waiting';
    end if;
    msg := 'No answer came back.';
  elsif coalesce(resp.timed_out, false) then
    msg := 'Claude took too long.';
  else
    begin
      body := resp.content::jsonb;
    exception when others then
      body := null;
    end;
    if resp.status_code is distinct from 200 then
      msg := 'Claude could not answer (' || coalesce(resp.status_code::text, 'no status') || '): '
             || left(coalesce(body #>> '{error,message}', resp.content, ''), 200);
    else
      select string_agg(b ->> 'text', '' order by n) into txt
        from jsonb_array_elements(coalesce(body -> 'content', '[]'::jsonb)) with ordinality e(b, n)
       where b ->> 'type' = 'text';
      txt := coalesce(txt, '');
      parts := string_to_array(txt, '```json');
      if array_length(parts, 1) > 1 then
        part := split_part(parts[array_length(parts, 1)], '```', 1);
      elsif strpos(txt, '{') > 0 then
        part := substring(txt from strpos(txt, '{'));
        part := left(part, length(part) - strpos(reverse(part), '}') + 1);
      end if;
      begin
        parsed := btrim(coalesce(part, ''))::jsonb;
      exception when others then
        parsed := null;
      end;
      if parsed is null or parsed ->> 'verdict' is null then
        msg := 'No clear answer' || case when body ->> 'stop_reason' = 'pause_turn'
                                         then ' (Claude ran out of steps).' else '.' end;
      end if;
    end if;
  end if;

  update public.listing_checks
     set done_at = now(),
         answer  = case when msg is null then parsed end,
         error   = msg,
         usage   = jsonb_strip_nulls(jsonb_build_object(
                     'in', body #> '{usage,input_tokens}',
                     'out', body #> '{usage,output_tokens}',
                     'searches', body #> '{usage,server_tool_use,web_search_requests}',
                     'fetches', body #> '{usage,server_tool_use,web_fetch_requests}')),
         -- Kept for checking how it reasoned; the response row itself
         -- is cleared by pg_net after a few hours.
         said    = left(nullif(txt, ''), 6000)
   where id = p_check;
  return case when msg is null then 'answered' else 'error' end;
end $$;
revoke all on function public.listing_check_collect(bigint) from public, anon, authenticated;

-- ------------------------------------------------ the job
create or replace function public.listing_check_auto(p_max int default 3)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      record;
  v      record;
  got    int := 0;
  asked  int := 0;
  failed int := 0;
  r      text;
begin
  if coalesce((select (s.value ->> 'on')::boolean from public.sync_settings s
                where s.key = 'listing_check_auto'), true) is false then
    return jsonb_build_object('off', true);
  end if;
  perform set_config('nomadwise.auto_check', '1', true);

  for c in
    select q.id from public.listing_checks q
     where q.done_at is null and q.request_id is not null
       and q.asked_at < now() - interval '20 seconds'
     order by q.id limit 40
  loop
    begin
      r := public.listing_check_collect(c.id);
      if r <> 'waiting' then got := got + 1; end if;
    exception when others then
      null;
    end;
  end loop;

  -- Not too many out at once: each takes up to a couple of minutes.
  if (select count(*) from public.listing_checks
       where done_at is null and asked_at > now() - interval '5 minutes') >= 6 then
    return jsonb_build_object('answers', got, 'asked', 0, 'busy', true);
  end if;

  for v in
    select x.id from public.venues x
     where x.website_status = 'queued'
       and x.website_approved_at is null
       and x.website_dismissed_at is null
       and x.website_prepared is not null
       and not exists (
             select 1 from public.listing_checks q
              where q.venue_id = x.id
                and (q.error is null or q.asked_at > now() - interval '30 minutes'))
       and (select count(*) from public.listing_checks q where q.venue_id = x.id) < 3
     order by x.created_at
     limit greatest(coalesce(p_max, 3), 0)
  loop
    begin
      perform public.listing_check_ask(v.id);
      asked := asked + 1;
    exception when others then
      failed := failed + 1;
      exit when sqlerrm like '%checks today%' or sqlerrm like '%Claude key%';
    end;
  end loop;

  return jsonb_build_object('answers', got, 'asked', asked, 'failed', failed);
end $$;
revoke all on function public.listing_check_auto(int) from public, anon, authenticated;

-- ------------------------------------------------ for the app
create or replace function public.admin_listing_checks_latest()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  return jsonb_build_object(
    'checks', coalesce((
      select jsonb_object_agg(t.venue_id, t.j) from (
        select distinct on (q.venue_id) q.venue_id::text as venue_id,
               q.answer || jsonb_strip_nulls(jsonb_build_object(
                 'check', q.id, 'at', q.done_at, 'feedback', q.feedback)) as j
          from public.listing_checks q
          join public.venues x on x.id = q.venue_id
         where x.website_status = 'queued'
           and q.done_at is not null and q.error is null and q.answer is not null
         order by q.venue_id, q.done_at desc) t), '{}'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(distinct q.venue_id::text)
        from public.listing_checks q
        join public.venues x on x.id = q.venue_id
       where x.website_status = 'queued' and q.done_at is null), '[]'::jsonb));
end $$;
revoke all on function public.admin_listing_checks_latest() from public, anon;
grant execute on function public.admin_listing_checks_latest() to authenticated;

-- "Claude got this wrong": his correction, in his words.
create or replace function public.admin_listing_check_wrong(p_check bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  c record;
  x record;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'founders only';
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'Say in a few words what it got wrong.';
  end if;
  select * into c from public.listing_checks where id = p_check;
  if c.id is null then
    raise exception 'No such check.';
  end if;
  select v.name, v.city, v.country into x from public.venues v where v.id = c.venue_id;
  update public.listing_checks set feedback = btrim(p_note), feedback_at = now()
   where id = p_check;
  insert into public.listing_judgements
    (venue_id, name, city, country, decision, note, check_verdict, check_said)
  values (c.venue_id, x.name, x.city, x.country, 'correction', btrim(p_note),
          c.answer ->> 'verdict', c.answer ->> 'reason');
end $$;
revoke all on function public.admin_listing_check_wrong(bigint, text) from public, anon;
grant execute on function public.admin_listing_check_wrong(bigint, text) to authenticated;

-- ------------------------------------------------ what he decided
create or replace function public.venues_listing_judgement()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  d   text;
  chk record;
begin
  if new.type is distinct from 'coworking' then
    return new;
  end if;
  if old.website_approved_at is null and new.website_approved_at is not null then
    d := 'approved';
  elsif old.website_dismissed_at is null and new.website_dismissed_at is not null then
    d := 'not_for_site';
  elsif old.website_status = 'queued' and new.website_status = 'not_on_site'
        and old.website_prepared is not null then
    d := 'sent_back';
  else
    return new;
  end if;
  begin
    select q.answer ->> 'verdict' as verdict, q.answer ->> 'reason' as said into chk
      from public.listing_checks q
     where q.venue_id = new.id and q.answer is not null
     order by q.done_at desc limit 1;
    insert into public.listing_judgements
      (venue_id, name, city, country, decision, reason, note, check_verdict, check_said)
    values (new.id, new.name, new.city, new.country, d,
            case when d = 'not_for_site' then new.website_dismiss_reason end,
            case when d = 'not_for_site' then new.website_dismiss_note end,
            chk.verdict, chk.said);
  exception when others then
    null;  -- never stands in the way of the change itself
  end;
  return new;
end $$;

drop trigger if exists venues_listing_judgement on public.venues;
create trigger venues_listing_judgement
  after update of website_approved_at, website_dismissed_at, website_status on public.venues
  for each row execute function public.venues_listing_judgement();

select cron.unschedule('listing-check-auto')
 where exists (select 1 from cron.job where jobname = 'listing-check-auto');
select cron.schedule('listing-check-auto', '*/2 * * * *',
                     $c$select public.listing_check_auto(3)$c$);

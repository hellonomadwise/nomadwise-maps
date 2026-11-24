-- ============================================================
-- Migration 356: a phone notice opens the screen it is about
-- (Jonathan, 24 Nov 2026: "click into that notification and it takes
-- me to the owner account for that change to approve, because
-- sometimes I then need to go to Nomad Maps, find it").
--
-- Chat notices already opened the chats (migration 207). Now the
-- notices that ask us to do something carry a link as well:
--   Owner changes to review     Owner changes, that space's card first
--   Update suggested            Owner changes (Suggested updates)
--   Owner price list to check   Price check
--   a claim to approve          Owners
--   Enquiry to pass on / held   Enquiries
--   Waiting on us               Home
-- Every other notice is as it was (no link).
--
-- notify_click(title, message) works the link out from the notice's
-- own words, so none of the functions that send a notice had to be
-- changed. The app reads &show (which list) and &space (which card).
-- ============================================================

create or replace function public.notify_click(p_title text, p_message text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  base constant text := 'https://nomadmaps.io/?admin';
  sp uuid;
begin
  if p_title = 'Owner changes to review' then
    -- The notice begins "<space name>: ...". The newest change of a
    -- space of that name is the one meant.
    select d.venue_id into sp
      from public.owner_drafts d
      join public.venues v on v.id = d.venue_id
     where left(coalesce(p_message, ''), length(v.name) + 2) = v.name || ': '
     order by d.updated_at desc
     limit 1;
    return base || '=centre&show=owner' || coalesce('&space=' || sp::text, '');
  elsif p_title like 'Update suggested:%' then
    return base || '=centre&show=owner';
  elsif p_title = 'Owner price list to check' then
    return base || '=prices';
  elsif p_title like '%claimed for free, approve?' or p_title = 'PAID, approve the claim' then
    return base || '=centre&show=paid';
  elsif p_title like 'Enquiry to pass on:%' or p_title like 'Enquiry held for Premium:%' then
    return base || '=centre&show=enquiries';
  elsif p_title like 'Waiting on us%' then
    return base;
  end if;
  return null;
exception when others then
  return null;
end $$;

revoke all on function public.notify_click(text, text) from public, anon, authenticated;

-- As migration 25, plus the link. The topic stays written out here:
-- chat_notify and its kin read it from this function's own text.
create or replace function public.notify_phone(
  p_title text, p_message text, p_tags text default 'bell')
returns void language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://ntfy.sh',
    body := jsonb_strip_nulls(jsonb_build_object(
      'topic', 'nomadmaps-83076iwunm',
      'title', p_title,
      'message', p_message,
      'tags', string_to_array(p_tags, ','),
      'click', public.notify_click(p_title, p_message))),
    headers := '{"Content-Type": "application/json"}'::jsonb);
exception when others then
  null; -- notifications are best-effort, never break the app
end $$;

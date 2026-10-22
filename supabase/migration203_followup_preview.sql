-- ============================================================
-- Migration 203: the "Did you find a place?" email, previewed as it
-- arrives.
--
-- Jonathan, 22 Oct 2026, on the email's dialog in Enquiries: "can I
-- see the preview on how this will look to the receiver, in terms of
-- styling". The words now live in one place, enquiry_followup_text,
-- used both by the daily send (migration 193's enquiry_followup_send,
-- otherwise unchanged) and by admin_followup_preview, which returns
-- the subject and the styled email exactly as the customer gets it
-- (the customer template, with the "Tell us where you went" button).
--
-- One change to the words: the sign-off is the one the other customer
-- emails use since migration 196 ("Jonathan Heavens", "Co-founder,
-- Nomadwise"). Everything else is as Leonie will review it.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.enquiry_followup_text(p_first text, p_names text[])
returns text language sql immutable set search_path = public as $$
  select 'Hi ' || coalesce(nullif(btrim(coalesce(p_first, '')), ''), 'there') || ',' || E'\n\n'
      || 'A few days ago you asked ' || public.enquiry_space_names(p_names)
      || ' on nomadwise.io about working there. Did you find a place?' || E'\n\n'
      || 'It takes one tap to tell us. It helps us know which spaces reply, so we '
      || 'can point other remote workers the right way.' || E'\n\n'
      || 'If you are still looking, reply to this email and I will help you find '
      || 'somewhere.' || E'\n\n'
      || 'Kind regards,' || E'\n' || 'Jonathan Heavens' || E'\n' || 'Co-founder, Nomadwise';
$$;
revoke all on function public.enquiry_followup_text(text, text[]) from public, anon, authenticated;

-- For Nomad Maps: the email with example names, as the customer sees it.
create or replace function public.admin_followup_preview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  body text := public.enquiry_followup_text(
    'Ellie', array['Xom Space', 'The Sentry C', 'GEEK Hub', 'Hello World Saigon',
                   'the Hive District 1', 'The Sentry Z']);
begin
  if not coalesce(public.is_admin(), false) then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'subject', 'Did you find a place to work?',
    'text', body,
    'html', public.email_html(body, 'Tell us where you went',
                              'https://nomadmaps.io/?found=preview', false));
end $$;
revoke all on function public.admin_followup_preview() from public, anon;
grant execute on function public.admin_followup_preview() to authenticated;

-- The daily send (migration 193), with its words from the function above.
create or replace function public.enquiry_followup_send()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r     record;
  tok   uuid;
  first text;
  sent  integer := 0;
begin
  if not coalesce((select (value ->> 'on')::boolean from public.sync_settings
                    where key = 'enquiry_followup'), false) then
    return 0;
  end if;
  for r in
    select lower(e.email) as em, min(e.name) as nm,
           array_agg(e.id order by e.passed_at) as ids,
           array_agg(v.name order by e.passed_at) as names
      from public.enquiries e
      join public.venues v on v.id = e.venue_id
     where e.status = 'passed'
       and e.passed_at >= timestamptz '2026-10-21 00:00:00+00'
       and e.passed_at <= now() - interval '5 days'
       and e.passed_at >= now() - interval '12 days'
       and e.followup_sent_at is null
       and e.outcome is null
       and position('@' in coalesce(e.email, '')) > 1
       -- asked at most once a month
       and not exists (select 1 from public.enquiries x
                        where lower(x.email) = lower(e.email)
                          and x.followup_sent_at > now() - interval '30 days')
     group by lower(e.email)
     limit 25
  loop
    tok := gen_random_uuid();
    first := nullif(nullif(split_part(btrim(r.nm), ' ', 1), ''), 'Someone');
    begin
      perform public.send_owner_email(
        r.em,
        'Did you find a place to work?',
        public.enquiry_followup_text(first, r.names),
        'enquiry_followup', tok::text,
        'Tell us where you went', 'https://nomadmaps.io/?found=' || tok::text);
      update public.enquiries
         set followup_token = tok, followup_sent_at = now()
       where id = any(r.ids);
      sent := sent + 1;
    exception when others then
      null; -- tried again tomorrow
    end;
  end loop;
  return sent;
end $$;
revoke all on function public.enquiry_followup_send() from public, anon, authenticated;
grant execute on function public.enquiry_followup_send() to service_role;

notify pgrst, 'reload schema';

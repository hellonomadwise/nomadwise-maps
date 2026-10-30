-- ============================================================
-- Migration 230: "Ask for more details" on an enquiry.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 30 Oct 2026: an enquiry for Fora, 22 Manchester Square said
-- only "Tuesday 3", too little to pass on. He asks the nomad for more
-- from his own inbox; Nomad Maps now records that he did, so the
-- enquiry stays in the list marked "Asked for more details" until the
-- answer comes and he passes it on. Nothing is sent from here.
--   * enquiries.asked_at / asked_note
--   * admin_enquiry_asked(p_id, p_undo): marks it (or takes it back)
--   * admin_enquiries_to_pass_on: its live version plus asked_at
-- Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.enquiries
  add column if not exists asked_at timestamptz,
  add column if not exists asked_note text;

create or replace function public.admin_enquiry_asked(
  p_id uuid, p_undo boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  update public.enquiries e
     set asked_at = case when p_undo then null else now() end,
         asked_note = case when p_undo then e.asked_note
                           else nullif(concat_ws(E'\n', nullif(e.asked_note, ''),
                                  'Asked for more details '
                                  || to_char(now() at time zone 'utc', 'YYYY-MM-DD') || '.'), '') end
   where e.id = p_id and e.status = 'waiting';
  if not found then
    raise exception 'This enquiry is no longer waiting.';
  end if;
end $$;
revoke all on function public.admin_enquiry_asked(uuid, boolean) from public, anon;
grant execute on function public.admin_enquiry_asked(uuid, boolean) to authenticated;

create or replace function public.admin_enquiries_to_pass_on()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  return jsonb_build_object(
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name, 'email', e.email, 'phone', e.phone,
               'message', e.message, 'dates', e.dates, 'created_at', e.created_at,
               'listing_text', e.listing_text, 'source', e.source,
               'asked_at', e.asked_at,
               'venue_id', v.id, 'venue_name', v.name, 'city', v.city,
               'slug', v.webflow_slug, 'website', v.website, 'instagram', v.instagram,
               'tier', coalesce(v.listing_tier, 'free'),
               'owner_email', v.listing_owner_email,
               'contact_emails', coalesce(to_jsonb(v.contact_emails), '[]'::jsonb),
               'contact_checked', v.contact_checked_at is not null,
               'earlier', (select count(*) from public.enquiries x
                            where x.venue_id = e.venue_id and x.id <> e.id))
             order by e.created_at)
        from public.enquiries e
        left join public.venues v on v.id = e.venue_id
       where e.status = 'waiting'), '[]'::jsonb),
    'passed_30d', (select count(*) from public.enquiries
                    where status = 'passed' and passed_at > now() - interval '30 days'),
    'direct_30d', (select count(*) from public.enquiries
                    where status = 'sent' and sent_at > now() - interval '30 days'),
    'booked_30d', (select count(*) from public.enquiries
                    where outcome = 'booked' and outcome_at > now() - interval '30 days'),
    'followup_on', coalesce((select (value ->> 'on')::boolean from public.sync_settings
                              where key = 'enquiry_followup'), false),
    'answers', coalesce((
      select jsonb_agg(a order by a ->> 'at' desc)
        from (select jsonb_build_object(
                       'name', min(e.name),
                       'outcome', case when bool_or(e.outcome = 'booked') then 'booked'
                                       else min(e.outcome) end,
                       'space', (select v2.name from public.enquiries e2
                                  join public.venues v2 on v2.id = e2.venue_id
                                 where e2.followup_token = e.followup_token
                                   and e2.outcome = 'booked' limit 1),
                       'asked', count(*),
                       'note', max(e.outcome_note),
                       'at', max(e.outcome_at)) as a
                from public.enquiries e
               where e.followup_token is not null and e.outcome is not null
               group by e.followup_token
               order by max(e.outcome_at) desc
               limit 8) s), '[]'::jsonb),
    'import', (select value from public.sync_settings where key = 'enquiry_import'));
end $function$;

-- ============================================================
-- Migration 291: Home, the spaces behind one outreach bar
-- ============================================================
-- Jonathan, 9 Nov 2026, on Home's "Outreach sent each week": "if i
-- click onto a particular bar, a modal appears showing me a breakdown
-- of each space contacted". admin_outreach_week(p_week) lists every
-- message we sent in the week starting that Monday (London time),
-- counted as admin_home counts them (migration 288: sent, not a test
-- contact): the space, where it is, the way (email, WhatsApp,
-- Instagram, Facebook, contact form), whether it has a page on
-- nomadwise.io, when, and where things stand with it now.
-- Admins only. Reads only.
-- ============================================================

create or replace function public.admin_outreach_week(p_week date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  wk date := date_trunc('week', p_week)::date;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'venue_id', c.venue_id,
             'contact_id', c.id,
             'name', coalesce(nullif(v.name, ''), c.space_name, 'A space'),
             'city', coalesce(nullif(v.city, ''), c.city),
             'country', coalesce(nullif(v.country, ''), c.country),
             'kind', coalesce(v.type, c.kind),
             'way', case m.subject
                      when 'WhatsApp' then 'whatsapp'
                      when 'Instagram' then 'instagram'
                      when 'Facebook' then 'facebook'
                      when 'Contact form' then 'form'
                      else 'email' end,
             'subject', case when m.subject in ('WhatsApp', 'Instagram', 'Facebook', 'Contact form')
                             then null else m.subject end,
             'listed', (v.id is not null and coalesce(v.webflow_slug, '') <> ''),
             'at', m.at,
             'stage', c.stage,
             'claimed', coalesce(btrim(v.listing_owner_email), '') <> '',
             'replied', exists (select 1 from public.outreach_messages i
                                 where i.contact_id = c.id and i.direction = 'in'
                                   and i.at > m.at))
           order by m.at)
      from public.outreach_messages m
      join public.space_contacts c on c.id = m.contact_id
      left join public.venues v on v.id = c.venue_id
     where m.direction = 'out' and m.send_error is null
       and not coalesce(c.is_test, false)
       and (m.at at time zone 'Europe/London') >= wk
       and (m.at at time zone 'Europe/London') < wk + 7), '[]'::jsonb);
end $$;

revoke all on function public.admin_outreach_week(date) from public, anon;
grant execute on function public.admin_outreach_week(date) to authenticated;

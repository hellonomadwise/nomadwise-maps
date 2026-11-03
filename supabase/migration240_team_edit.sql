-- ============================================================
-- Migration 240: the team can edit a space's details (Team edit).
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 3 Nov 2026: "make it so we can edit coworking space
-- details". Leonie had opened a space's Owner account from the
-- control centre, changed things and saved, and it was gone: that
-- screen is a preview and saves nothing. Team edit is the same screen
-- (any space, claimed or not), and it saves.
--
--   admin_team_save(venue, draft)  founders only. The same fields and
--     limits as an owner's draft (owner_save_draft): description,
--     prices, hours, facts, website, Instagram, WhatsApp, enquiry
--     address, photos, and on a Premium page the promotion. It is
--     filed as a draft from "team" and put on at once, exactly as
--     "Put on the page" does with an owner's changes
--     (owner_apply_draft): the venue is updated and the page is synced
--     to nomadwise.io by the ten-minute website push. No email goes to
--     anybody (the owner_draft_emails trigger only writes to an
--     address with an @). The space's History shows it as the team's.
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.admin_team_save(p_venue uuid, p_draft jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  clean jsonb;
  d_id  uuid;
  done  jsonb;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if not exists (select 1 from public.venues where id = p_venue) then
    raise exception 'Space not found.';
  end if;
  if pg_column_size(p_draft) > 60000 then
    raise exception 'That is too much text; please shorten it.';
  end if;

  -- The keys the editor knows, trimmed as an owner's are.
  clean := jsonb_strip_nulls(jsonb_build_object(
    'description', left(coalesce(p_draft->>'description', ''), 8000),
    'prices', jsonb_build_object(
        'day',    left(coalesce(p_draft#>>'{prices,day}', ''), 60),
        'week',   left(coalesce(p_draft#>>'{prices,week}', ''), 60),
        'month',  left(coalesce(p_draft#>>'{prices,month}', ''), 60),
        'coffee', left(coalesce(p_draft#>>'{prices,coffee}', ''), 60)),
    'hours', coalesce(p_draft->'hours', '{}'::jsonb),
    'facts', coalesce(p_draft->'facts', '{}'::jsonb),
    'website', left(coalesce(p_draft->>'website', ''), 300),
    'instagram', left(coalesce(p_draft->>'instagram', ''), 300),
    'whatsapp', left(coalesce(p_draft->>'whatsapp', ''), 60),
    'enquiry_email', lower(left(coalesce(p_draft->>'enquiry_email', ''), 200)),
    'photos', coalesce(p_draft->'photos', '[]'::jsonb),
    'mention', case when p_draft ? 'mention' then jsonb_build_object(
        'kind',  left(coalesce(p_draft#>>'{mention,kind}', ''), 20),
        'title', left(coalesce(p_draft#>>'{mention,title}', ''), 90),
        'body',  left(coalesce(p_draft#>>'{mention,body}', ''), 300),
        'cta',   left(coalesce(p_draft#>>'{mention,cta}', ''), 40),
        'url',   left(coalesce(p_draft#>>'{mention,url}', ''), 300))
      else null end));

  insert into public.owner_drafts (venue_id, owner_email, draft, status, submitted_at)
  values (p_venue, 'team', clean, 'submitted', now())
  returning id into d_id;

  done := public.owner_apply_draft(d_id);
  return coalesce(done, '{}'::jsonb) || jsonb_build_object('draft_id', d_id);
end $$;
revoke all on function public.admin_team_save(uuid, jsonb) from public, anon;
grant execute on function public.admin_team_save(uuid, jsonb) to authenticated;

-- ============================================================
-- Migration 282: "Your changes" emails greet the owner by name.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: the changes-live and changes-returned emails
-- opened with "Hi," and no name; now "Hi Marta," like the others, or
-- "Hi there," when we have no first name (or the name box holds the
-- business name, such as "Hotel AMANO").
-- ============================================================

create or replace function public.owner_first_name(p_venue uuid, p_email text default null)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare
  v     public.venues%rowtype;
  em    text;
  first text;
begin
  select * into v from public.venues where id = p_venue;
  em := lower(btrim(coalesce(p_email, v.listing_owner_email, '')));
  first := nullif(split_part(btrim(coalesce(
             case when lower(btrim(coalesce(v.listing_owner_email, ''))) = em then nullif(btrim(v.listing_owner_name), '') end,
             (select lc.owner_name from public.listing_claims lc
               where lower(lc.owner_email) = em and coalesce(btrim(lc.owner_name), '') <> ''
               order by (lc.venue_id = p_venue) desc nulls last, lc.created_at desc limit 1),
             '')), ' ', 1), '');
  if first is null
     or lower(first) in ('hotel', 'team', 'the', 'info', 'sales', 'admin', 'hello', 'cafe', U&'caf\00E9', 'coworking',
                         'cowork', 'manager', 'management', 'reception', 'contact', 'office', 'space', 'studio', 'hub')
     or position(' ' || lower(first) || ' ' in ' ' || lower(coalesce(v.name, '')) || ' ') > 0 then
    return 'there';
  end if;
  return first;
end $$;
revoke all on function public.owner_first_name(uuid, text) from public, anon, authenticated;

select public.pm_patch_fn('public.owner_draft_emails()',
  $a$jsonb_build_object('first_name', '', 'space_name', space,$a$,
  $a$jsonb_build_object('first_name', public.owner_first_name(new.venue_id, em), 'space_name', space,$a$,
  $m$public.owner_first_name(new.venue_id, em)$m$);

update public.email_templates
   set html_body = replace(html_body, '#142032;">Hi,</p>', '#142032;">Hi {{first_name}},</p>'),
       text_body = regexp_replace(text_body, '^Hi,', 'Hi {{first_name}},'),
       updated_at = now()
 where alias in ('changes-live', 'changes-returned') and html_body like '%>Hi,</p>%';

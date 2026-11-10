-- ============================================================
-- Migration 311: the email says the space's short name
-- ============================================================
-- Jonathan, 10 Nov 2026: the email to Uncommon Borough said
-- "Uncommon Borough - Flexible Office Work Space" three times. Asked
-- whether the body should say "Uncommon Borough" and keep the full
-- name for the subject: "I think so yes please".
--
-- A line tied to a page: the subject keeps the page's full name, the
-- body says the short one ("Uncommon Borough"), but only when the
-- short name is this space's alone. "Fora - 133 Whitechapel High
-- Street" stays whole: "Fora" is 59 pages, and the part after the
-- dash is the one that says which. (A line with no page already goes
-- by its short name everywhere: migration 308.)
-- ============================================================

create or replace function public.outreach_short_name(p_name text, p_venue uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  brand text := public.outreach_brand(p_name);
begin
  if brand is null or brand = btrim(coalesce(p_name, '')) or length(brand) < 3 then
    return p_name;
  end if;
  -- shared with another place: the full name is the one that tells them apart
  if exists (select 1 from public.venues v2
              where v2.id is distinct from p_venue
                and left(lower(v2.name), length(brand)) = lower(brand)
                and lower(public.outreach_brand(v2.name)) = lower(brand)) then
    return p_name;
  end if;
  return brand;
end $$;

revoke all on function public.outreach_short_name(text, uuid) from public, anon, authenticated;

select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
$a$  body := replace(body, '{space}', space);$a$,
$a$  -- the body says the short name when it is this space's alone (migration 311)
  body := replace(body, '{space}', case when c.venue_id is not null
                                        then public.outreach_short_name(space, c.venue_id)
                                        else space end);$a$,
$m$when it is this space's alone (migration 311)$m$);

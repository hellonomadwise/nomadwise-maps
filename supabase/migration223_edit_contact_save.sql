-- migration223_edit_contact_save.sql
-- Outreach, "Edit contact" (Jonathan, 25 Oct 2026: "after i clicked
-- save, nothing happened ... nothing had been saved").
--
-- 1. A refused save says why, in plain words, and names the other line
--    when the email is already on one (one line per address).
-- 2. An email that is not an address is refused before anything is
--    written.
-- 3. The space on the map is looked up again only when the name or the
--    city really changed. Before, every save looked it up again, which
--    could move a line to another branch with the same name.
--
-- Pure ASCII. Safe to run twice.

create or replace function public.admin_outreach_update(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  c        public.space_contacts%rowtype;
  em       text;
  other_id uuid;
  other_nm text;
  other_ct text;
  new_name text;
  new_city text;
  moved    boolean := false;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  select * into c from public.space_contacts where id = p_id;
  if not found then
    raise exception 'This line is no longer in Outreach, so nothing was saved. Close this and search for the space again.';
  end if;

  if p ? 'email' then
    em := nullif(lower(trim(p->>'email')), '');
    if em is not null and (position('@' in em) < 2 or position('.' in split_part(em, '@', 2)) < 2
                           or position(' ' in em) > 0) then
      raise exception using message =
        'The email "' || em || '" does not look like an address, so nothing was saved.';
    end if;
    if em is not null and em is distinct from lower(coalesce(c.email, '')) then
      select o.id, o.space_name, o.city into other_id, other_nm, other_ct
        from public.space_contacts o
       where lower(o.email) = em and o.id <> c.id
       limit 1;
      if other_id is not null then
        raise exception using message =
          em || ' is already on another line in Outreach: '
          || coalesce(other_nm, 'no name')
          || coalesce(' (' || nullif(trim(other_ct), '') || ')', '')
          || '. One line per address, so nothing was saved. Search for that line,'
          || ' or leave the email empty here and save the rest.';
      end if;
    end if;
  end if;

  new_name := coalesce(nullif(trim(p->>'space_name'), ''), c.space_name);
  new_city := case when p ? 'city' then nullif(trim(p->>'city'), '') else c.city end;
  moved := (p ? 'space_name' and lower(trim(coalesce(new_name, ''))) <> lower(trim(coalesce(c.space_name, ''))))
        or (p ? 'city' and lower(trim(coalesce(new_city, ''))) <> lower(trim(coalesce(c.city, ''))));

  update public.space_contacts x set
    stage        = coalesce(nullif(p->>'stage', ''), x.stage),
    notes        = case when p ? 'notes' then nullif(trim(p->>'notes'), '') else x.notes end,
    follow_up_on = case when p ? 'follow_up_on' then nullif(p->>'follow_up_on', '')::date else x.follow_up_on end,
    venue_id     = case when p ? 'venue_id' then nullif(p->>'venue_id', '')::uuid
                        -- a new name or city: look for the space on the map again
                        when moved then coalesce(public.outreach_match_venue(new_name, new_city), x.venue_id)
                        else x.venue_id end,
    space_name   = new_name,
    person_name  = case when p ? 'person_name' then nullif(trim(p->>'person_name'), '') else x.person_name end,
    email        = case when p ? 'email' then em else x.email end,
    phone        = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else x.phone end,
    city         = new_city,
    country      = case when p ? 'country' then nullif(trim(p->>'country'), '') else x.country end,
    kind         = case when p ? 'kind' then nullif(trim(p->>'kind'), '') else x.kind end,
    website      = case when p ? 'website' then nullif(trim(p->>'website'), '') else x.website end,
    instagram    = case when p ? 'instagram' then nullif(trim(p->>'instagram'), '') else x.instagram end
  where x.id = p_id;
end $$;
revoke all on function public.admin_outreach_update(uuid, jsonb) from public, anon;
grant execute on function public.admin_outreach_update(uuid, jsonb) to authenticated;

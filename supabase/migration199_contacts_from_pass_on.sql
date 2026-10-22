-- ============================================================
-- Migration 199: addresses and numbers added by hand reach Outreach.
--
-- Jonathan, 22 Oct 2026, on Pass on (Step 1): when he types an email
-- address by hand and sends, it should be kept in the "CRM" for that
-- listing, and the same for phone numbers.
--
-- Outreach's record for a space is its contact (space_contacts, one
-- email and one phone). Now:
--   * Pass on: the address it went to is kept on the space's contact
--     (it was already kept on the space itself, for next time). No
--     contact yet: one is made. The contact had a different address:
--     the new one, where the conversation now is, becomes the main
--     one and the old one is kept in the notes. An address another
--     contact already has (a chain's shared address) goes in the
--     notes instead.
--   * Step 1 has a phone or WhatsApp box per space with its own
--     "Save to Outreach" button (admin_contact_remember): kept the
--     same way, nothing is sent.
--
-- Pure ASCII. Safe to apply twice.
-- ============================================================

create or replace function public.outreach_remember_contact(
  p_venue uuid, p_email text, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v     public.venues%rowtype;
  c     public.space_contacts%rowtype;
  em    text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ph    text := nullif(btrim(regexp_replace(coalesce(p_phone, ''), '[^0-9+() -]', '', 'g')), '');
  taken boolean := false;
  day   text := to_char(now() at time zone 'utc', 'FMDD Mon YYYY');
  lines text[] := '{}';
begin
  if p_venue is null then return null; end if;
  if em is not null and em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    em := null;
  end if;
  if ph is not null and length(regexp_replace(ph, '[^0-9]', '', 'g')) < 7 then
    ph := null;
  end if;
  if em is null and ph is null then return null; end if;

  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;

  -- the space's contact: the one with this address, else the oldest
  select * into c from public.space_contacts
   where venue_id = p_venue
   order by (lower(coalesce(email, '')) = coalesce(em, '#')) desc,
            coalesce(is_test, false), created_at
   limit 1;

  if em is not null then
    taken := exists (select 1 from public.space_contacts x
                      where lower(x.email) = em and x.id is distinct from c.id);
  end if;

  if c.id is null then
    insert into public.space_contacts
      (venue_id, space_name, kind, city, country, email, phone, website, instagram,
       source, stage, notes)
    values (v.id, v.name, v.type, nullif(btrim(coalesce(v.city, '')), ''),
            nullif(btrim(coalesce(v.country, '')), ''),
            case when taken then null else em end, ph,
            nullif(btrim(coalesce(v.website, '')), ''),
            nullif(btrim(coalesce(v.instagram, '')), ''),
            'listing', 'new',
            case when taken then 'Also reached at ' || em || ' (added by hand, ' || day || ')' end)
    returning * into c;
    return c.id;
  end if;

  if em is not null and lower(coalesce(c.email, '')) <> em then
    if taken then
      lines := lines || ('Also reached at ' || em || ' (added by hand, ' || day || ')');
    else
      if c.email is not null then
        lines := lines || ('Earlier address: ' || c.email || ' (replaced ' || day || ')');
      end if;
      c.email := em;
      -- a bounced address replaced by one that works: back to new.
      -- Unsubscribed was their own choice and stays.
      if c.stage = 'bounced' then
        c.stage := 'new';
      elsif c.stage = 'unsubscribed' then
        lines := lines || ('New address added after they unsubscribed (' || day
                           || '): check before writing to them.');
      end if;
    end if;
  end if;

  if ph is not null and coalesce(c.phone, '') <> ph then
    if nullif(btrim(coalesce(c.phone, '')), '') is not null then
      lines := lines || ('Earlier phone: ' || c.phone || ' (replaced ' || day || ')');
    end if;
    c.phone := ph;
  end if;

  update public.space_contacts
     set email = c.email,
         phone = c.phone,
         stage = c.stage,
         stage_at = case when c.stage is distinct from stage then now() else stage_at end,
         notes = case when coalesce(array_length(lines, 1), 0) = 0 then notes
                      else concat_ws(E'\n', nullif(btrim(coalesce(notes, '')), ''),
                                     array_to_string(lines, E'\n')) end,
         updated_at = now()
   where id = c.id;
  return c.id;
end $$;
revoke all on function public.outreach_remember_contact(uuid, text, text) from public, anon, authenticated;

-- Nomad Maps: keep an address or number on a space's contact by hand.
create or replace function public.admin_contact_remember(
  p_venue uuid, p_email text default null, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cid uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  cid := public.outreach_remember_contact(p_venue, p_email, p_phone);
  if cid is null then
    raise exception 'That does not look like an email address or phone number.';
  end if;
  return (select jsonb_build_object('id', c.id, 'email', c.email, 'phone', c.phone)
            from public.space_contacts c where c.id = cid);
end $$;
revoke all on function public.admin_contact_remember(uuid, text, text) from public, anon;
grant execute on function public.admin_contact_remember(uuid, text, text) to authenticated;

-- Pass on (migration 194), plus: the address is kept in Outreach.
create or replace function public.admin_enquiry_pass_on(
  p_id uuid, p_to text, p_tell_nomad boolean default true,
  p_subject text default null, p_body text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e     public.enquiries%rowtype;
  v     public.venues%rowtype;
  dest  text := lower(trim(coalesce(p_to, '')));
  draft jsonb;
  nd    jsonb;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'admin only';
  end if;
  if dest !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That does not look like an email address.';
  end if;
  select * into e from public.enquiries where id = p_id for update;
  if not found then raise exception 'Enquiry not found.'; end if;
  if e.status <> 'waiting' then
    raise exception 'This enquiry has already been dealt with.';
  end if;
  if e.venue_id is null then
    raise exception 'Choose the space first.';
  end if;
  select * into v from public.venues where id = e.venue_id;
  draft := public.enquiry_space_email(p_id);

  perform public.send_enquiry_mail(
    dest, e.email,
    coalesce(nullif(btrim(p_subject), ''), draft ->> 'subject'),
    coalesce(nullif(btrim(p_body), ''), draft ->> 'body'),
    'enquiry_passed', e.id::text, v.id);

  update public.enquiries
     set status = 'passed', passed_to = dest, passed_at = now(),
         to_email = dest, sent_at = now(), send_error = null
   where id = p_id;

  -- Remember the address for the next one.
  update public.venues
     set contact_emails = array_prepend(dest, array_remove(coalesce(contact_emails, '{}'), dest))
   where id = v.id;

  -- ... and in Outreach, on the space's contact (migration 199). Never
  -- in the way of the email that has just gone.
  begin
    perform public.outreach_remember_contact(v.id, dest, null);
  exception when others then
    null;
  end;

  if p_tell_nomad then
    nd := public.enquiry_nomad_email(array[p_id]);
    perform public.send_enquiry_mail(
      e.email, 'hello@nomadwise.io', nd ->> 'subject', nd ->> 'body',
      'enquiry_passed_nomad', e.id::text, v.id, null);
    update public.enquiries set nomad_emailed_at = now() where id = p_id;
  end if;

  return jsonb_build_object('status', 'passed', 'to', dest);
end $$;
revoke all on function public.admin_enquiry_pass_on(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.admin_enquiry_pass_on(uuid, text, boolean, text, text) to authenticated;

notify pgrst, 'reload schema';

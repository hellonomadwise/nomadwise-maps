-- ============================================================
-- Migration 231: a personal opening line on each first email, and
-- the hello to a space listed a while ago.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 30 Oct 2026, on the Outreach 5 morning list: "how do I go
-- from reading that to agreeing and then going, yeah, let's get in
-- touch with them ... you've drafted the email and I can literally go
-- copy ... open up Spark ... and then I can confirm that I've sent the
-- email". And which words: "this depends on whether we've only
-- recently added them to nomadwise or not. if only recently then
-- [the new page hello]. if they've been listed on nomadwise (they
-- might know or not) ... We just wanted to let you know that we now
-- have a members area where you can manage your listing on nomadwise."
--
--   * space_contacts.opening_line: one friendly sentence about
--     something real from the space's own page, written by the
--     morning run (Outreach 5). Shown nowhere to the space by itself.
--   * admin_outreach_preview: a first email (nothing sent to them
--     yet) opens with that sentence, right after "Hi there,", so Reply
--     in the Outreach tool gives the whole email ready for "From my
--     own inbox" and "I sent it". A reply, a follow-up or a WhatsApp
--     message is left as it is.
--   * invite_listed (the hello to a space on the site for a while)
--     says what is new: the members area where they manage their own
--     listing. Reply already picks it for a cold space that was on
--     the site before us, and invite_new_page for a page we put live.
--   * outreach_five_note(id, line, note): the one door the morning run
--     writes through. It sets the opening line and adds its note to
--     the card, and nothing else: no stage, no dates, no messages. A
--     select, so the database connector runs it without asking anyone
--     to confirm (30 Oct 2026: the run's updates waited for a
--     confirmation nobody was there to give).
-- Nothing is sent by itself. Pure ASCII. Safe to apply twice.
-- ============================================================

alter table public.space_contacts
  add column if not exists opening_line text;
comment on column public.space_contacts.opening_line is
  'One personal sentence for the first email, written by the morning run; put after the greeting by admin_outreach_preview.';

-- The hello to a space listed a while ago: the news is the members
-- area. Reworded only while it still carries its old first line.
update public.outreach_templates
   set name = 'First contact: listed a while, now a members area (email)',
       subject = '{space} on nomadwise.io: your page is now yours to manage',
       body = 'Hi there,

{space} has had a page on nomadwise.io for a while now, where remote workers and digital nomads look for good places to work from. Here it is: {page_link}

We just wanted to let you know that we now have a members area, where you can manage your listing yourself. Claiming your page is free, and from your own Owner account you can update your opening hours and contact details and add your own photos, description and prices whenever it suits you:

{claim_link}

If you ever want a little extra visibility, there is also an optional Nomadwise Premium plan, and you will find the details in your Owner account.

We hope it helps a few more people find you.

{signoff}',
       updated_at = now()
 where key = 'invite_listed'
   and body like '%has a page on nomadwise.io, the directory nomads use to find a place to work from%';

create or replace function public.admin_outreach_preview(p_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c   public.space_contacts%rowtype;
  v   public.venues%rowtype;
  t   public.outreach_templates%rowtype;
  first_name text;
  space text;
  city  text;
  page_link text;
  claim_link text;
  price text;
  subj text;
  body text;
  line text;
  cut  integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;
  if not found then raise exception 'Contact not found.'; end if;
  select * into t from public.outreach_templates where key = p_key;
  if not found then raise exception 'No such template.'; end if;
  if c.venue_id is not null then
    select * into v from public.venues where id = c.venue_id;
  end if;

  first_name := coalesce(nullif(split_part(trim(coalesce(c.person_name, '')), ' ', 1), ''), 'there');
  space := coalesce(nullif(trim(c.space_name), ''), v.name, 'your space');
  city  := coalesce(nullif(trim(c.city), ''), v.city, 'your city');
  page_link := case when v.webflow_cms_id is not null and coalesce(v.webflow_slug, '') <> ''
                    then 'https://www.nomadwise.io/coworking/' || v.webflow_slug end;
  -- (from= says where the link was sent, so a visit through it is
  -- known as an answer to our message: migration 156)
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
             || case when right(p_key, 3) = '_wa' then '&from=whatsapp' else '&from=email' end
             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;
  price := case when coalesce(v.country, c.country, '') <> ''
                     and coalesce((public.pricing_for(coalesce(v.country, c.country))->>'ready')::boolean, false)
                then public.verified_price_words(coalesce(v.country, c.country))
                else 'around a day pass a month' end;

  subj := t.subject; body := t.body;
  -- The subject takes the words, not the links.
  subj := replace(subj, '{space}', space);
  subj := replace(subj, '{first_name}', first_name);
  subj := replace(subj, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  subj := replace(subj, '{city}', city);
  body := replace(body, '{first_name}', first_name);
  body := replace(body, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  body := replace(body, '{space}', space);
  body := replace(body, '{city}', city);
  body := replace(body, '{page_link}', coalesce(page_link, 'https://www.nomadwise.io'));
  body := replace(body, '{claim_link}', claim_link);
  body := replace(body, '{price_words}', price);
  body := replace(body, '{unsubscribe_link}', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
  -- The sign-off (migration 183): an email closes as a letter; a
  -- WhatsApp message keeps the short one.
  body := replace(body, '{signoff}',
            case when right(p_key, 3) = '_wa'
                 then E'Jonathan\nNomadwise, https://www.nomadwise.io'
                 else E'Kind regards,\nJonathan Heavens\nCofounder - Nomadwise.io' end);

  -- The personal opening line (migration 231): on a first email only,
  -- as its own paragraph straight after the greeting. The line is
  -- placed by position, never by pattern, so its own words cannot
  -- change the email.
  line := btrim(coalesce(c.opening_line, ''));
  if line <> '' and right(p_key, 3) <> '_wa' and c.last_out_at is null then
    cut := position(E'\n\n' in body);
    if cut > 0 and left(body, cut - 1) ~ '^Hi\M' and cut < 80 then
      body := left(body, cut + 1) || line || E'\n\n' || substr(body, cut + 2);
    else
      body := line || E'\n\n' || body;
    end if;
  end if;

  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream,
                            'opening_line', nullif(line, ''),
                            'unsubscribe_link', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

-- The morning run's one door: the opening line (replaced: there is
-- one per space) and a note on the card (added, never replaced).
-- Either part may be left out. Returns what the card now holds.
create or replace function public.outreach_five_note(
  p_id uuid, p_line text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.space_contacts%rowtype;
begin
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  update public.space_contacts
     set opening_line = case when btrim(coalesce(p_line, '')) <> ''
                             then left(btrim(p_line), 400) else opening_line end,
         notes = case when btrim(coalesce(p_note, '')) <> ''
                      then coalesce(notes || E'\n', '') || left(btrim(p_note), 1200)
                      else notes end
   where id = p_id;
  select * into c from public.space_contacts where id = p_id;
  return jsonb_build_object('ok', true, 'space', c.space_name,
                            'opening_line', c.opening_line,
                            'notes_tail', right(coalesce(c.notes, ''), 300));
end $$;
revoke all on function public.outreach_five_note(uuid, text, text) from public, anon, authenticated;

notify pgrst, 'reload schema';

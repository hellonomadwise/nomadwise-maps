-- ============================================================
-- Migration 122: Outreach emails sent from our own inbox.
-- (Applied automatically by the build; nothing to paste.)
--
-- Outreach (migration 121) sends through Postmark, which suits a reply
-- to someone who wrote to us. An invitation to a space that never
-- wrote is better sent as an ordinary email from our own mailbox, by a
-- person: "Open in mail app" in the control centre opens the filled-in
-- email as a draft in Spark, the founder sends it there, and this
-- records it. Two changes:
--   * admin_outreach_preview() also returns the contact's unsubscribe
--     link, so the draft can carry it;
--   * admin_outreach_log_sent() records an email sent that way and
--     moves the stage on, with the same guard rails as a Postmark send
--     (never to someone who unsubscribed, 30 days between emails
--     unless forced, 40 a day).
-- ============================================================

-- A template with the contact's details filled in: {subject, body}.
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
  claim_link := 'https://nomadmaps.io/?claim='
             || public.form_enc(coalesce(v.webflow_slug, space))
             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;
  price := case when coalesce(v.country, c.country, '') <> ''
                     and coalesce((public.pricing_for(coalesce(v.country, c.country))->>'ready')::boolean, false)
                then public.verified_price_words(coalesce(v.country, c.country))
                else 'around a day pass a month' end;

  subj := t.subject; body := t.body;
  subj := replace(subj, '{space}', space);
  body := replace(body, '{first_name}', first_name);
  body := replace(body, '{name}', coalesce(nullif(trim(c.person_name), ''), 'there'));
  body := replace(body, '{space}', space);
  body := replace(body, '{city}', city);
  body := replace(body, '{page_link}', coalesce(page_link, 'https://www.nomadwise.io'));
  body := replace(body, '{claim_link}', claim_link);
  body := replace(body, '{price_words}', price);
  body := replace(body, '{unsubscribe_link}', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
  body := replace(body, '{signoff}', E'Jonathan\nNomadwise, https://www.nomadwise.io');
  return jsonb_build_object('subject', subj, 'body', body, 'to', c.email,
                            'page_link', page_link, 'claim_link', claim_link,
                            'stream', t.stream,
                            'unsubscribe_link', 'https://nomadmaps.io/?unsubscribe=' || c.unsub_token);
end $$;
revoke all on function public.admin_outreach_preview(uuid, text) from public, anon;
grant execute on function public.admin_outreach_preview(uuid, text) to authenticated;

-- An email the founder sent from their own mail app. Nothing is sent
-- from here: this is the record, and the stage moving on.
create or replace function public.admin_outreach_log_sent(
  p_id uuid, p_subject text, p_body text, p_template text default null,
  p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.space_contacts%rowtype;
  today_n integer;
  who     text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id for update;
  if not found then raise exception 'Contact not found.'; end if;
  if c.unsubscribed_at is not null then
    raise exception 'They asked us not to write again.';
  end if;
  if not p_force and c.last_out_at is not null and c.last_out_at > now() - interval '30 days' then
    raise exception 'We wrote to them on % already. Tick "send anyway" to record another.',
      to_char(c.last_out_at, 'DD Mon');
  end if;
  select count(*) into today_n from public.outreach_messages
   where direction = 'out' and send_error is null and at >= date_trunc('day', now());
  if today_n >= 40 then
    raise exception 'That is 40 outreach emails today, which is the daily limit. Tomorrow.';
  end if;
  who := coalesce((select email from auth.users where id = auth.uid()), 'founder');
  insert into public.outreach_messages (contact_id, direction, template_key, subject, body, sent_by)
  values (c.id, 'out', p_template, nullif(trim(p_subject), ''), left(coalesce(p_body, ''), 4000),
          who || ' (own inbox)');
  update public.space_contacts
     set last_out_at = now(),
         stage = case when stage in ('new', 'contacted', 'not_now', 'replied') then 'contacted' else stage end
   where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.admin_outreach_log_sent(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.admin_outreach_log_sent(uuid, text, text, text, boolean) to authenticated;

-- Whether sending a contact another email is allowed right now, before
-- a draft is opened: '' when it is, otherwise the reason in words.
create or replace function public.admin_outreach_can_send(p_id uuid, p_force boolean default false)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  c       public.space_contacts%rowtype;
  today_n integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into c from public.space_contacts where id = p_id;
  if not found then return 'Contact not found.'; end if;
  if c.email is null then return 'This contact has no email address.'; end if;
  if c.unsubscribed_at is not null then return 'They asked us not to write again.'; end if;
  if not p_force and c.last_out_at is not null and c.last_out_at > now() - interval '30 days' then
    return 'We wrote to them on ' || to_char(c.last_out_at, 'DD Mon')
        || ' already. Tick "send anyway" to write again.';
  end if;
  select count(*) into today_n from public.outreach_messages
   where direction = 'out' and send_error is null and at >= date_trunc('day', now());
  if today_n >= 40 then
    return 'That is 40 outreach emails today, which is the daily limit. Tomorrow.';
  end if;
  return '';
end $$;
revoke all on function public.admin_outreach_can_send(uuid, boolean) from public, anon;
grant execute on function public.admin_outreach_can_send(uuid, boolean) to authenticated;

-- The price sentence read twice over ("for €10 a month or €99 a year,
-- monthly or yearly, cancel any time"). The price words already say
-- monthly or yearly, so the templates now end "for {price_words}.
-- Cancel any time." A template a founder has already reworded is left
-- alone: the old words are simply not found in it.
update public.outreach_templates
   set body = replace(replace(body,
                ', for {price_words}, monthly or yearly, cancel any time.',
                ', for {price_words}. Cancel any time.'),
                ', that is {price_words}, monthly or yearly, cancel any time.',
                ', that is {price_words}. Cancel any time.'),
       updated_at = now()
 where body like '%{price_words}, monthly or yearly, cancel any time.%';

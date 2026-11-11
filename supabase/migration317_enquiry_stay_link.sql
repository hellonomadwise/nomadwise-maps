-- ============================================================
-- Migration 317: "somewhere to stay" in the nomad's confirmation
-- ============================================================
-- Jonathan, 11 Nov 2026. Step 2's fallback from the stay-enquiries
-- plan (project doc listings/2026-11-11-stay-enquiries-plan.md),
-- brought forward: when a nomad ticked "I also need somewhere to
-- stay" (migration 315), the email they already get has a link to
-- places to stay around the space they asked about. His conditions:
-- "relevant to where they are looking, and its fluid and doesn't
-- damage our overall brand", and the commission said "in a more
-- fluid way, where the user will think 'fair enough'". He chose
-- wording 1 of three ("i like 1"):
--
--   You also asked about somewhere to stay. Here are places to stay
--   near {space}, on a map with prices.  [See places to stay nearby]
--   If you book through that link, the booking site pays us a small
--   commission. It costs you nothing extra, and it helps keep
--   Nomadwise free to use.
--
-- * The link is short and on our own address:
--   nomadmaps.io/stay/?to=<lat>_<lng>_<region slug>. The page
--   app/web/stay/index.html sends the person on to Stay22 (the
--   partner already on the region pages), on a map around the SPACE's
--   own coordinates, campaign enquiry-<region slug>. One place to
--   change if the partner link ever changes; no "&" for an email
--   program to break.
-- * Once only: in the first email the nomad gets about that enquiry
--   ("We have your request", or "Your request has been sent" when it
--   goes straight to the space). Not again when it is passed on.
-- * Only when they ticked the box and the space has coordinates.
-- * No dates on the link: the pop-up has no date field.
--
-- The two Postmark templates are pushed by hand after this
-- (pm_templates_backup(), pm_template_push(alias, true) for
-- enquiry-received-nomad and enquiry-sent-nomad).
-- ============================================================

create or replace function public.enquiry_stay_url(p_id uuid)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select 'https://nomadmaps.io/stay/?to='
         || round(v.lat::numeric, 4)::text || '_' || round(v.lng::numeric, 4)::text || '_'
         || coalesce(nullif(regexp_replace(lower(coalesce(r.slug, '')), '[^a-z0-9-]', '', 'g'), ''), 'other')
    from public.enquiries e
    join public.venues v on v.id = e.venue_id
    left join public.webflow_regions r on r.id = v.webflow_region_id
   where e.id = p_id
     and e.wants_stay
     and v.lat is not null and v.lng is not null
     and v.lat between -90 and 90 and v.lng between -180 and 180;
$function$;

-- The link for the FIRST email about an enquiry only.
create or replace function public.enquiry_stay_first(p_id uuid)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select public.enquiry_stay_url(e.id)
    from public.enquiries e
   where e.id = p_id and e.nomad_ack_at is null;
$function$;

-- The same words for an email that goes as plain text ('' when there
-- is nothing to say).
create or replace function public.enquiry_stay_text(p_id uuid)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce((
    select 'You also asked about somewhere to stay. Here are places to stay near '
           || v.name || ', on a map with prices.' || E'\n'
           || public.enquiry_stay_first(e.id) || E'\n\n'
           || 'If you book through that link, the booking site pays us a small commission. '
           || 'It costs you nothing extra, and it helps keep Nomadwise free to use.' || E'\n\n'
      from public.enquiries e
      join public.venues v on v.id = e.venue_id
     where e.id = p_id and public.enquiry_stay_first(e.id) is not null), '');
$function$;

revoke all on function public.enquiry_stay_url(uuid) from public, anon, authenticated;
revoke all on function public.enquiry_stay_first(uuid) from public, anon, authenticated;
revoke all on function public.enquiry_stay_text(uuid) from public, anon, authenticated;

-- "We have your request"
select public.pm_patch_fn('public.enquiry_received_email(uuid)',
$a$'enquiry_phone', coalesce(nullif(btrim(coalesce(e.phone, '')), ''), ''))$a$,
$a$'enquiry_phone', coalesce(nullif(btrim(coalesce(e.phone, '')), ''), ''),
      'stay_url', coalesce(public.enquiry_stay_first(e.id), ''))$a$,
$m$'stay_url'$m$);

select public.pm_patch_fn('public.enquiry_received_email(uuid)',
$a$|| public.enquiry_what_you_sent(p_id) || E'\n\n'$a$,
$a$|| public.enquiry_what_you_sent(p_id) || E'\n\n'
      || public.enquiry_stay_text(p_id)$a$,
$m$public.enquiry_stay_text(p_id)$m$);

-- "Your request has been sent to X" (one space)
select public.pm_patch_fn('public.enquiry_nomad_email(uuid[])',
$a$'enquiry_phone', coalesce(nullif(btrim(coalesce(x.phone, '')), ''), ''))$a$,
$a$'enquiry_phone', coalesce(nullif(btrim(coalesce(x.phone, '')), ''), ''),
        'stay_url', coalesce(public.enquiry_stay_first(x.id), ''))$a$,
$m$'stay_url'$m$);

select public.pm_patch_fn('public.enquiry_nomad_email(uuid[])',
$a$|| public.enquiry_what_you_sent(p_ids[1]) || E'\n\n'$a$,
$a$|| public.enquiry_what_you_sent(p_ids[1]) || E'\n\n'
        || public.enquiry_stay_text(p_ids[1])$a$,
$m$public.enquiry_stay_text(p_ids[1])$m$);

-- The two Postmark templates: the same block, after "Your details".
update public.email_templates
   set html_body = replace(html_body,
$h$<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If anything needs changing, or you would like to add something, simply reply to this email.</p>$h$,
$h${{#stay_url}}<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">You also asked about somewhere to stay. Here are places to stay near {{../space_or_the_space}}, on a map with prices.<br><a href="{{../stay_url}}" style="color:#FF444F;font-weight:700;text-decoration:underline;">See places to stay nearby</a></p>
<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If you book through that link, the booking site pays us a small commission. It costs you nothing extra, and it helps keep Nomadwise free to use.</p>
{{/stay_url}}<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If anything needs changing, or you would like to add something, simply reply to this email.</p>$h$),
       text_body = replace(text_body,
$t$If anything needs changing, or you would like to add something, simply reply to this email.$t$,
$t${{#stay_url}}You also asked about somewhere to stay. Here are places to stay near {{../space_or_the_space}}, on a map with prices.
{{../stay_url}}

If you book through that link, the booking site pays us a small commission. It costs you nothing extra, and it helps keep Nomadwise free to use.

{{/stay_url}}If anything needs changing, or you would like to add something, simply reply to this email.$t$),
       updated_at = now()
 where alias = 'enquiry-received-nomad'
   and html_body not like '%stay_url%';

update public.email_templates
   set html_body = replace(html_body,
$h${{#website}}<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If you would like to contact them yourself as well$h$,
$h${{#stay_url}}<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">You also asked about somewhere to stay. Here are places to stay near {{../space_name}}, on a map with prices.<br><a href="{{../stay_url}}" style="color:#FF444F;font-weight:700;text-decoration:underline;">See places to stay nearby</a></p>
<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If you book through that link, the booking site pays us a small commission. It costs you nothing extra, and it helps keep Nomadwise free to use.</p>
{{/stay_url}}{{#website}}<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">If you would like to contact them yourself as well$h$),
       text_body = replace(text_body,
$t${{#website}}If you would like to contact them yourself as well$t$,
$t${{#stay_url}}You also asked about somewhere to stay. Here are places to stay near {{../space_name}}, on a map with prices.
{{../stay_url}}

If you book through that link, the booking site pays us a small commission. It costs you nothing extra, and it helps keep Nomadwise free to use.

{{/stay_url}}{{#website}}If you would like to contact them yourself as well$t$),
       updated_at = now()
 where alias = 'enquiry-sent-nomad'
   and html_body not like '%stay_url%';

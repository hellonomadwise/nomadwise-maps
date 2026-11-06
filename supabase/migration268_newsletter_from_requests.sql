-- ============================================================
-- Migration 268: nomads who tick "newsletter" on a request join Kit.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 6 Nov 2026: requests on listing pages should let the nomad
-- join the Nomadwise newsletter (for nomads, not owners), and anyone
-- who does goes into Kit. Growing the list is its own mission; the
-- footer sign-up gets almost nothing.
--
-- Both request forms on a listing page end up as the Webflow "Research
-- Form", whose "Agree-to-Receive-Marketing-2" box is already filed as
-- enquiries.marketing_ok by the ten-minute import (migration 113). The
-- site's own pop-up has always had the box; the price list pop-up
-- (prices.js) gets its own tick box with this change.
--
-- Every ten minutes this adds each new "yes" to Kit:
--  * already in Kit and still subscribed: just tagged,
--  * not in Kit: added as a subscriber (first name too), then tagged,
--  * in Kit but unsubscribed: left alone (their choice wins).
-- The tag is "Nomad: request form" (Kit tag 25507455), so the nomad
-- list stays apart from space owners and you can see how many came
-- from requests. The 12 who said yes before today are picked up on the
-- first run (8 of them were already in Kit by hand).
-- ============================================================

alter table public.enquiries
  add column if not exists kit_synced_at timestamptz,
  add column if not exists kit_note      text,
  add column if not exists kit_tries     int not null default 0;

create or replace function public.kit_call(p_method text, p_path text, p_body jsonb default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  k text;
  r record;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'kit_api_key';
  if k is null then raise exception 'kit_api_key is not in Vault'; end if;
  select * into r from extensions.http((p_method, 'https://api.kit.com/v4/' || p_path,
    array[extensions.http_header('X-Kit-Api-Key', k), extensions.http_header('Accept', 'application/json')],
    case when p_body is null then null else 'application/json' end,
    case when p_body is null then null else p_body::text end)::extensions.http_request);
  return jsonb_build_object('status', r.status,
    'body', case when r.content ~ '^\s*[\{\[]' then r.content::jsonb else to_jsonb(left(coalesce(r.content, ''), 300)) end);
end $$;
revoke all on function public.kit_call(text, text, jsonb) from public, anon, authenticated;

create or replace function public.kit_sync_nomads() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  TAG constant bigint := 25507455;   -- Kit tag "Nomad: request form"
  e     record;
  em    text;
  res   jsonb;
  sub   jsonb;
  first text;
  note  text;
  n_add int := 0; n_tag int := 0; n_skip int := 0; n_err int := 0;
begin
  for e in
    select id, name, email from public.enquiries
     where marketing_ok and kit_synced_at is null and coalesce(btrim(email), '') <> '' and kit_tries < 3
     order by created_at
     limit 25
  loop
    em := lower(btrim(e.email));
    note := null;
    begin
      res := public.kit_call('GET', 'subscribers?status=all&email_address=' || replace(replace(em, '+', '%2B'), '&', '%26'));
      if (res->>'status')::int <> 200 then raise exception 'look-up %', res->>'status'; end if;
      sub := res #> '{body,subscribers,0}';
      if sub is not null and coalesce(sub->>'state', '') <> 'active' then
        note := 'in Kit but ' || coalesce(sub->>'state', '?') || ', left alone';
        n_skip := n_skip + 1;
      else
        if sub is null then
          first := nullif(split_part(btrim(coalesce(e.name, '')), ' ', 1), '');
          res := public.kit_call('POST', 'subscribers',
            jsonb_strip_nulls(jsonb_build_object('email_address', em, 'first_name', first, 'state', 'active')));
          if (res->>'status')::int not in (200, 201, 202) then
            raise exception 'add % %', res->>'status', left((res->'body')::text, 160);
          end if;
          n_add := n_add + 1;
          note := 'added to Kit';
        else
          note := 'already in Kit';
        end if;
        res := public.kit_call('POST', 'tags/' || TAG || '/subscribers', jsonb_build_object('email_address', em));
        if (res->>'status')::int not in (200, 201, 202) then
          raise exception 'tag % %', res->>'status', left((res->'body')::text, 160);
        end if;
        n_tag := n_tag + 1;
        note := note || ', tagged';
      end if;
      update public.enquiries set kit_synced_at = now(), kit_note = note, kit_tries = kit_tries + 1 where id = e.id;
    exception when others then
      n_err := n_err + 1;
      update public.enquiries set kit_tries = kit_tries + 1, kit_note = left(sqlerrm, 200) where id = e.id;
    end;
  end loop;
  return jsonb_build_object('added', n_add, 'tagged', n_tag, 'left_alone', n_skip, 'failed', n_err);
end $$;
revoke all on function public.kit_sync_nomads() from public, anon, authenticated;

select cron.unschedule('kit-nomad-sync')
 where exists (select 1 from cron.job where jobname = 'kit-nomad-sync');
select cron.schedule('kit-nomad-sync', '4-59/10 * * * *', 'select public.kit_sync_nomads()');

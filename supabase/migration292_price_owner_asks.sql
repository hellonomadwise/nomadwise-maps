-- ============================================================
-- Migration 292: Price check remembers what we asked the owner
-- ============================================================
-- Jonathan, 9 Nov 2026: "once ive asked owner to check for the
-- specific products we are questioning. this worth checking should
-- go no?". "Ask the owner to check" now records which points were
-- asked and when. Those points leave "Worth checking before a Go"
-- and a single line says they were asked, and whether the owner has
-- written in Chats since. A new point (other prices, or a change)
-- shows again. Asking again replaces the record.
--
-- price_owner_asks: one row per space, the latest ask.
--   admin_price_ask_record(p_venue, p_keys)  after the message is sent
--   admin_price_ask(p_venue)                 the owner's first name (when
--                                            we know it), asked_at, keys,
--                                            and when the owner last wrote
--                                            in Chats after that
-- Admins only.
-- ============================================================

create table if not exists public.price_owner_asks (
  venue_id   uuid primary key references public.venues(id) on delete cascade,
  asked_at   timestamptz not null default now(),
  keys       text[] not null default '{}',
  asked_by   text
);

alter table public.price_owner_asks enable row level security;
-- no policies: read and written only through the functions below

create or replace function public.admin_price_ask_record(p_venue uuid, p_keys text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  insert into public.price_owner_asks (venue_id, asked_at, keys, asked_by)
  values (p_venue, now(), coalesce(p_keys, '{}'),
          (select email from auth.users where id = auth.uid()))
  on conflict (venue_id) do update
    set asked_at = excluded.asked_at, keys = excluded.keys, asked_by = excluded.asked_by;
end $$;

create or replace function public.admin_price_ask(p_venue uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a     public.price_owner_asks%rowtype;
  v     public.venues%rowtype;
  who   text;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  select * into v from public.venues where id = p_venue;
  -- The owner's first name, for "Hi Amani," (Jonathan, 9 Nov 2026:
  -- "this should be personalised to the person using the owner
  -- account if we know it"): the name on the listing, else on their
  -- latest claim. Only a plain word is used.
  who := coalesce(nullif(btrim(v.listing_owner_name), ''),
                  (select nullif(btrim(lc.owner_name), '') from public.listing_claims lc
                    where lc.venue_id = p_venue
                      and lower(lc.owner_email) = lower(btrim(v.listing_owner_email))
                      and lc.status in ('free', 'paid')
                    order by lc.created_at desc limit 1));
  who := split_part(coalesce(who, ''), ' ', 1);
  if who !~ '^[[:alpha:]][[:alpha:]''-]{1,29}$' then
    who := null;
  else
    who := upper(left(who, 1)) || substr(who, 2);
  end if;
  select * into a from public.price_owner_asks where venue_id = p_venue;
  return jsonb_build_object(
    'owner_first', who,
    'asked_at', a.asked_at,
    'keys', coalesce(to_jsonb(a.keys), '[]'::jsonb),
    'replied_at', case when a.asked_at is null then null else
                    (select max(m.at) from public.space_chat_messages m
                      where m.venue_id = p_venue and not m.from_team
                        and m.at > a.asked_at) end);
end $$;

revoke all on function public.admin_price_ask_record(uuid, text[]) from public, anon;
grant execute on function public.admin_price_ask_record(uuid, text[]) to authenticated;
revoke all on function public.admin_price_ask(uuid) from public, anon;
grant execute on function public.admin_price_ask(uuid) to authenticated;

-- The first ask, sent before this was kept: Westerwelle Startup Haus
-- Arusha, 9 Nov 2026, about its four points.
insert into public.price_owner_asks (venue_id, asked_at, keys)
select m.venue_id, max(m.at),
       array['per:Dedicated desk', 'per:Hot desk', 'per:Private office', 'ask:Month pass']
  from public.space_chat_messages m
 where m.venue_id = '0f13c4dd-fa78-4588-8786-ceb01f0d4731'
   and m.from_team and m.body like '%Before they go on your page%'
 group by m.venue_id
on conflict (venue_id) do nothing;

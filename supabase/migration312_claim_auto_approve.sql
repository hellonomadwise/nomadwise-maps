-- ============================================================
-- Migration 312: a claim from the space's own email is approved by itself
-- ============================================================
-- Jonathan, 11 Nov 2026, after Olga (olga@stonesoup.io) claimed Stone
-- Soup and waited for him to press Approve: "I wondered if it makes
-- sense, for situations where a person signing up is doing so with an
-- email address that is linked to the space, like olga@stonesoup.io if
-- that situation can be auto approved?"
--
-- Why it is safe: an Owner account is opened only by a sign-in link
-- sent to the claim's email address. So whoever typed the form, the
-- page goes to the person who reads that mailbox, and a mailbox on the
-- space's own website address belongs to the space. That is the same
-- thing the green line on the claim card ("Email domain matches the
-- space's website") asked Jonathan to confirm by hand.
--
-- A claim is approved by itself when ALL of these hold:
--   * the page is already live on nomadwise.io (so its website is the
--     one we found and checked, not one typed on the claim form);
--   * the email is on that website's own address (olga@stonesoup.io for
--     stonesoup.io);
--   * nobody else is the owner on record;
--   * a claim from this address for this page was never turned down,
--     and this owner was never taken off the page;
--   * (Premium) enquiries go to the same address or one that passes
--     the same test.
-- Never by itself: a space not on the site yet, a website that is a
-- social page or a site builder's address, free mail (gmail...), and
-- schools and public bodies (one address for thousands of people).
--
-- The owner gets the "page is yours" email at once and not the "we are
-- checking" one. Jonathan gets a phone ping saying why, the claim keeps
-- the reason (listing_claims.auto_approved), and Owners shows the last
-- ones with an off switch (sync_settings 'claim_auto').
-- Owners' changes are still read before they go on the page.
-- ============================================================

alter table public.listing_claims add column if not exists auto_approved text;

insert into public.sync_settings (key, value)
values ('claim_auto', '{"on": true}'::jsonb)
on conflict (key) do nothing;

-- A mail domain that can stand for one business: not free mail, not a
-- site builder or social platform, not a school or public body, not a
-- bare ending like co.uk.
create or replace function public.claim_mail_domain_ok(p_dom text)
returns boolean language sql immutable as $$
  select coalesce(p_dom, '') ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$'
     and p_dom !~ '^(co|com|org|net|ac|gov|edu|or|ne|go|gob|sch)\.[a-z]{2}$'
     and p_dom !~ '(^|\.)(edu|gov|mil)$'
     and p_dom !~ '(^|\.)(ac|edu|gov|gob|go|sch)\.[a-z]{2}$'
     and p_dom not in (
       -- free mail
       'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'hotmail.co.uk',
       'hotmail.fr', 'hotmail.es', 'hotmail.it', 'hotmail.de', 'live.com', 'live.co.uk',
       'msn.com', 'yahoo.com', 'yahoo.co.uk', 'yahoo.fr', 'yahoo.es', 'yahoo.de',
       'yahoo.it', 'yahoo.com.br', 'yahoo.co.id', 'yahoo.co.in', 'ymail.com',
       'icloud.com', 'me.com', 'mac.com', 'aol.com', 'proton.me', 'protonmail.com',
       'pm.me', 'gmx.com', 'gmx.de', 'gmx.net', 'web.de', 'mail.com', 'mail.ru',
       'yandex.com', 'yandex.ru', 'zoho.com', 'hey.com', 'fastmail.com', 'tutanota.com',
       'tuta.io', 'qq.com', '163.com', '126.com', 'naver.com', 'daum.net', 'hanmail.net',
       'seznam.cz', 'wp.pl', 'o2.pl', 'libero.it', 'orange.fr', 'wanadoo.fr', 'free.fr',
       'laposte.net', 't-online.de', 'btinternet.com', 'sky.com', 'comcast.net',
       'verizon.net', 'att.net', 'sapo.pt', 'uol.com.br', 'bol.com.br', 'terra.com.br',
       'rediffmail.com',
       -- a page on somebody else's address
       'wixsite.com', 'wix.com', 'wordpress.com', 'squarespace.com', 'weebly.com',
       'webflow.io', 'business.site', 'google.com', 'godaddysites.com', 'carrd.co',
       'notion.site', 'github.io', 'blogspot.com', 'linktr.ee', 'facebook.com',
       'fb.com', 'instagram.com', 'tripadvisor.com', 'booking.com', 'airbnb.com',
       'yelp.com', 'foursquare.com', 'choiceqr.com', 'shopify.com', 'myshopify.com',
       'canva.site', 'framer.website', 'framer.app', 'netlify.app', 'vercel.app',
       'web.app', 'firebaseapp.com', 'herokuapp.com', 'glide.page', 'bio.link',
       'beacons.ai', 'taplink.cc', 'mystrikingly.com', 'jimdosite.com', 'jimdofree.com',
       'site123.me', 'ueniweb.com', 'wa.me', 'whatsapp.com', 't.me', 'youtube.com',
       'tiktok.com', 'x.com', 'twitter.com', 'linkedin.com', 'coworker.com',
       'bit.ly', 'goo.gl', 'page.link', 'mailchimpsites.com', 'hubspotpagebuilder.com')
$$;

-- Is this address the space's own? The reason in words, or null.
create or replace function public.claim_email_is_spaces(p_venue uuid, p_email text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v    public.venues%rowtype;
  em   text := lower(btrim(coalesce(p_email, '')));
  dom  text := split_part(em, '@', 2);
  site text;
begin
  if p_venue is null or position('@' in em) < 2 or dom = '' then return null; end if;
  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;

  -- on the website's own address: the same, or one a level above or
  -- below it (lisbon.brand.com and @brand.com; brand.com and @mail.brand.com)
  site := public.outreach_own_domain(v.website);
  if site is not null and public.claim_mail_domain_ok(dom) and public.claim_mail_domain_ok(site)
     and (dom = site
          or right(site, length(dom) + 1) = '.' || dom
          or right(dom, length(site) + 1) = '.' || site) then
    return 'Their email is on the space''s own website address (' || site || ').';
  end if;

  -- (Not enough by itself: an address found on the space's website,
  -- venues.contact_emails. Those were gathered by a script and hold
  -- placeholders (info@company.com) and web agencies' addresses, so a
  -- claim from one of them still waits for Jonathan.)
  return null;
end $$;

-- May this claim be approved with no check? The reason, or null.
create or replace function public.claim_auto_reason(p_venue uuid, p_email text, p_enquiry text default null)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v   public.venues%rowtype;
  em  text := lower(btrim(coalesce(p_email, '')));
  enq text := lower(btrim(coalesce(p_enquiry, '')));
  why text;
begin
  if p_venue is null or em = '' then return null; end if;
  -- the switch in Owners
  if not coalesce((select (s.value->>'on')::boolean from public.sync_settings s
                    where s.key = 'claim_auto'), true) then
    return null;
  end if;
  select * into v from public.venues where id = p_venue;
  if not found then return null; end if;
  -- only a page that is live: its website is the one we found
  if coalesce(v.webflow_slug, '') = '' or v.website_retired_at is not null then return null; end if;
  -- somebody else is the owner on record
  if coalesce(btrim(v.listing_owner_email), '') <> ''
     and lower(btrim(v.listing_owner_email)) <> em then
    return null;
  end if;
  -- turned down before, or taken off this page before
  if exists (select 1 from public.listing_claims k
              where k.venue_id = p_venue and lower(btrim(k.owner_email)) = em
                and (k.status = 'rejected'
                     or (k.status = 'abandoned' and k.approved_at is not null))) then
    return null;
  end if;
  why := public.claim_email_is_spaces(p_venue, em);
  if why is null then return null; end if;
  -- Premium: enquiries must not be sent somewhere else
  if enq <> '' and enq <> em and public.claim_email_is_spaces(p_venue, enq) is null then
    return null;
  end if;
  return why;
end $$;

revoke all on function public.claim_email_is_spaces(uuid, text) from public, anon, authenticated;
revoke all on function public.claim_auto_reason(uuid, text, text) from public, anon, authenticated;

-- ---- approving, without the "admin only" door, for the two places
-- ---- that approve by themselves. approve_claim() keeps the door.
do $$
declare
  src  text;
  door text := E'  if not public.is_admin() then\n    raise exception ''admin only'';\n  end if;\n';
begin
  select p.prosrc into src from pg_proc p
   where p.oid = 'public.approve_claim(uuid)'::regprocedure;
  if position('claim_approve_do' in src) > 0 then
    return;   -- done already
  end if;
  if position(door in src) = 0 then
    raise exception 'migration 312: approve_claim does not start as expected';
  end if;
  execute format(
    'create or replace function public.claim_approve_do(p_claim uuid) returns jsonb '
    'language plpgsql security definer set search_path = public as %L',
    replace(src, door, ''));
  execute $f$
    create or replace function public.approve_claim(p_claim uuid)
    returns jsonb language plpgsql security definer set search_path = public as $b$
    begin
      if not public.is_admin() then
        raise exception 'admin only';
      end if;
      return public.claim_approve_do(p_claim);
    end $b$
  $f$;
end $$;

revoke all on function public.claim_approve_do(uuid) from public, anon, authenticated;

-- ---- the "we are checking" emails are not sent for a claim that is
-- ---- approved in the same breath
select public.pm_patch_fn('public.claim_emails()',
$a$  -- Free claim just made.$a$,
$a$  -- approved by itself (migration 312): the owner hears "the page is
  -- yours" once, not "we are checking" first
  if coalesce(current_setting('nomadwise.claim_auto', true), '') = '1'
     and ((tg_op = 'INSERT' and new.status = 'free_pending')
          or (tg_op = 'UPDATE' and new.status = 'awaiting_approval')) then
    return new;
  end if;

  -- Free claim just made.$a$,
$m$approved by itself (migration 312)$m$);

-- ---- a free claim
select public.pm_patch_fn('public.start_claim(jsonb)',
$a$  free  boolean := lower(coalesce(p->>'plan', '')) = 'free';$a$,
$a$  free  boolean := lower(coalesce(p->>'plan', '')) = 'free';
  auto_why text;   -- why it needs no check, or null (migration 312)$a$,
$m$why it needs no check, or null (migration 312)$m$);

select public.pm_patch_fn('public.start_claim(jsonb)',
$a$  insert into public.listing_claims ($a$,
$a$  -- from the space's own email address: no check needed (migration 312)
  if free and v_id is not null then
    auto_why := public.claim_auto_reason(v_id, em, null);
    if auto_why is not null then
      perform set_config('nomadwise.claim_auto', '1', true);
    end if;
  end if;

  insert into public.listing_claims ($a$,
$m$no check needed (migration 312)$m$);

select public.pm_patch_fn('public.start_claim(jsonb)',
$a$
  if free then
    perform public.notify_phone($a$,
$a$
  if auto_why is not null then
    -- approved here and now, and Jonathan is told why (migration 312).
    -- If that fails for any reason, the claim waits for him as before.
    begin
      perform public.claim_approve_do(c_id);
      update public.listing_claims set auto_approved = auto_why where id = c_id;
    exception when others then
      auto_why := null;
    end;
    perform set_config('nomadwise.claim_auto', '', true);
  end if;
  if auto_why is not null then
    perform public.notify_phone(
      label || ' claimed, approved by itself',
      nm || ' (' || em || ') claimed ' || label || ' for free. ' || auto_why ||
        ' No check was needed. If it looks wrong, take the owner off in Owners.',
      'white_check_mark');
  elsif free then
    perform public.notify_phone($a$,
$m$approved here and now, and Jonathan is told why (migration 312)$m$);

select public.pm_patch_fn('public.start_claim(jsonb)',
$a$'plan', case when free then 'free' else 'verified' end);$a$,
$a$'plan', case when free then 'free' else 'verified' end,
                            -- so the thank-you page can say the page is theirs (migration 312)
                            'approved', auto_why is not null);$a$,
$m$the thank-you page can say the page is theirs (migration 312)$m$);

-- ---- a paid claim on a page already on the site
select public.pm_patch_fn('public.claim_paid(uuid,jsonb)',
$a$  paid   text;$a$,
$a$  paid   text;
  auto_why text;   -- why Premium goes on with no check, or null (migration 312)$a$,
$m$why Premium goes on with no check, or null (migration 312)$m$);

select public.pm_patch_fn('public.claim_paid(uuid,jsonb)',
$a$    held := true;$a$,
$a$    -- paid from the space's own email address: no wait (migration 312)
    auto_why := public.claim_auto_reason(v_id, c.owner_email, c.enquiry_email);
    if auto_why is not null then
      perform set_config('nomadwise.claim_auto', '1', true);
    end if;
    held := auto_why is null;$a$,
$m$paid from the space's own email address: no wait (migration 312)$m$);

select public.pm_patch_fn('public.claim_paid(uuid,jsonb)',
$a$    perform public.notify_phone(
      'PAID, approve the claim',
      coalesce(v_name, c.space_name, 'A space') || ' paid ' || paid || ' through the claim form. ' ||
        'Nothing changes on the page until you approve it in Owners.',
      'moneybag');$a$,
$a$    if auto_why is not null then
      -- Premium goes on now, and Jonathan is told why (migration 312).
      -- If that fails for any reason, the claim waits for him as before.
      begin
        perform public.claim_approve_do(p_claim);
        update public.listing_claims set auto_approved = auto_why where id = p_claim;
      exception when others then
        auto_why := null;
        held := true;
      end;
      perform set_config('nomadwise.claim_auto', '', true);
    end if;
    if auto_why is not null then
      perform public.notify_phone(
        'PAID, Premium is on',
        coalesce(v_name, c.space_name, 'A space') || ' paid ' || paid || ' through the claim form. ' ||
          auto_why || ' Premium went on with no check needed. If it looks wrong, take the owner off in Owners.',
        'moneybag');
    else
      perform public.notify_phone(
        'PAID, approve the claim',
        coalesce(v_name, c.space_name, 'A space') || ' paid ' || paid || ' through the claim form. ' ||
          'Nothing changes on the page until you approve it in Owners.',
        'moneybag');
    end if;$a$,
$m$Premium goes on now, and Jonathan is told why (migration 312)$m$);

-- ---- for Owners in the control centre: the switch and the last ones
create or replace function public.admin_claim_auto()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'on', coalesce((select (s.value->>'on')::boolean from public.sync_settings s
                     where s.key = 'claim_auto'), true),
    'total', (select count(*) from public.listing_claims where auto_approved is not null),
    'recent', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb)
                 from (select c.id, c.venue_id, coalesce(v.name, c.space_name) as space,
                              c.owner_name, c.owner_email, c.plan, c.status,
                              c.auto_approved as why, c.approved_at as at
                         from public.listing_claims c
                         left join public.venues v on v.id = c.venue_id
                        where c.auto_approved is not null
                        order by c.approved_at desc nulls last
                        limit 8) x));
end $$;

create or replace function public.admin_claim_auto_set(p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  insert into public.sync_settings (key, value, updated_at)
  values ('claim_auto', jsonb_build_object('on', coalesce(p_on, true)), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('on', coalesce(p_on, true));
end $$;

revoke all on function public.admin_claim_auto() from public, anon;
revoke all on function public.admin_claim_auto_set(boolean) from public, anon;
grant execute on function public.admin_claim_auto() to authenticated;
grant execute on function public.admin_claim_auto_set(boolean) to authenticated;

notify pgrst, 'reload schema';

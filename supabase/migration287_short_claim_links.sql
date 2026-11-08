-- ============================================================
-- Migration 287: short claim links, and the new first-contact email.
-- (Applied automatically by the build; nothing to paste.)
--
-- Jonathan, 8 Nov 2026 ("yes please" to the review of the round 1
-- email). The claim link in the first email was long and showed the
-- owner's email address in it (…&email=luis%40madeirafriends.org),
-- which looks like a phishing link in a first email from us. Now:
--
--   nomadmaps.io/c/portugal-madeira-friends-hub-k7q2
--
-- The space's own name, and 4 random letters so nobody can guess
-- another space's link. nomadmaps.io/c/... is answered by the site's
-- 404 page (c.js), which asks the database for the space and the
-- address it was sent to, and opens the claim form exactly as the
-- long link did (?claim=<slug>&from=email&email=<address>), so a visit
-- still counts as an answer to our message.
--
-- One link per space, address and channel (email or WhatsApp), made
-- the first time Outreach writes the hello and reused after.
--
-- The email itself (invite_listed), rewritten with Emily's checks:
-- one job (claim the page), the step made small ("free, about a
-- minute, no password"), an easy reply, and no Premium line in a
-- first email. The WhatsApp version keeps its words, with the short
-- link.
-- ============================================================

create table if not exists public.claim_links (
  code        text primary key,
  slug        text not null,
  email       text,
  channel     text not null default 'email',
  created_at  timestamptz not null default now(),
  opened_at   timestamptz,
  opens       int not null default 0
);
create unique index if not exists claim_links_one on public.claim_links (slug, coalesce(email, ''), channel);
alter table public.claim_links enable row level security;
revoke all on public.claim_links from public, anon, authenticated;

-- The link for a space (made once, then reused).
create or replace function public.claim_link_code(p_slug text, p_email text, p_channel text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare
  em   text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  ch   text := case when p_channel = 'whatsapp' then 'whatsapp' else 'email' end;
  c    text;
  i    int := 0;
begin
  if coalesce(btrim(p_slug), '') = '' then return null; end if;
  select code into c from public.claim_links
   where slug = p_slug and coalesce(email, '') = coalesce(em, '') and channel = ch;
  if c is not null then return c; end if;
  loop
    -- 4 letters and digits, without ones that are easy to misread
    c := p_slug || '-' || (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789',
                                  1 + floor(random() * 31)::int, 1), '') from generate_series(1, 4));
    begin
      insert into public.claim_links (code, slug, email, channel) values (c, p_slug, em, ch);
      return c;
    exception when unique_violation then
      i := i + 1;
      if i > 5 then raise; end if;
      -- the same space and address may have been added at the same moment
      select code into c from public.claim_links
       where slug = p_slug and coalesce(email, '') = coalesce(em, '') and channel = ch;
      if c is not null then return c; end if;
    end;
  end loop;
end $$;
revoke all on function public.claim_link_code(text, text, text) from public, anon, authenticated;

-- What the site's /c/ page asks: where this link goes. Open to anyone
-- with the link (that is what a link is for), and it only says the
-- space and the address the link was sent to.
create or replace function public.claim_link_open(p_code text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  l public.claim_links%rowtype;
begin
  update public.claim_links set opens = opens + 1, opened_at = coalesce(opened_at, now())
   where code = lower(btrim(coalesce(p_code, '')))
  returning * into l;
  if not found then return null; end if;
  return jsonb_build_object('slug', l.slug, 'email', l.email, 'from', l.channel);
end $$;
revoke all on function public.claim_link_open(text) from public;
grant execute on function public.claim_link_open(text) to anon, authenticated;

-- Outreach writes the short link.
select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
  $a$  claim_link := 'https://nomadmaps.io/?claim='$a$,
  $a$  -- the short link (migration 287); the long one only when there is no page
  claim_link := case when v.webflow_slug is not null then
      'https://nomadmaps.io/c/' || public.claim_link_code(v.webflow_slug, c.email,
        case when right(p_key, 3) = '_wa' then 'whatsapp' else 'email' end) end;
  claim_link := coalesce(claim_link, 'https://nomadmaps.io/?claim='$a$,
  $m$the short link (migration 287)$m$);

-- the closing bracket for the coalesce above
select public.pm_patch_fn('public.admin_outreach_preview(uuid,text)',
  $a$             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end;$a$,
  $a$             || case when c.email is not null then '&email=' || public.form_enc(c.email) else '' end);$a$,
  $m$public.form_enc(c.email) else '' end);$m$);

-- The first-contact email, rewritten.
update public.outreach_templates
   set subject = '{space} on Nomadwise, now yours to manage',
       body = E'Hi {space} team,\n\n'
           || E'{space} has a page on Nomadwise, where remote workers look for places to work in {city}: {page_link}\n\n'
           || E'You can now claim it for free. Once it is yours, you can update your opening hours, photos, prices and description whenever you like, and see how many people look at your page each month.\n\n'
           || E'Claim your page: {claim_link}\n'
           || E'It is free, takes about a minute, and there is no password to remember.\n\n'
           || E'If anything on the page is wrong, just reply and I will fix it.\n\n'
           || '{signoff}',
       updated_at = now()
 where key = 'invite_listed';

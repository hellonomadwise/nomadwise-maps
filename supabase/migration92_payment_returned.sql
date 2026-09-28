-- ============================================================
-- Migration 92: pick up a payment the moment the owner is back.
-- (Applied automatically by the build; nothing to paste.)
--
-- Payments reached us only when the Stripe sync next ran (with the
-- website push every 10 minutes, or hourly), so an owner who had just
-- paid saw "payment not finished" in their Owner account, and our
-- phone heard late (second paid test, 28 Sep). Now the thank-you page
-- and the Owner account ask for a sync straight away: this function
-- starts the "Stripe plans" run on GitHub for that one claim, and the
-- account shows "confirming your payment" until it lands.
--
-- Anyone who has a claim's id may ask (the owner is usually not
-- signed in yet), so it is narrow: only a Verified claim still
-- waiting for its payment, made in the last 6 hours, at most once
-- every 2 minutes per claim and 30 times an hour in all. It only
-- starts a read of Stripe; nothing is marked paid unless Stripe says
-- so.
-- ============================================================

alter table public.listing_claims
  add column if not exists sync_nudged_at timestamptz;

create or replace function public.payment_returned(p_claim uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  c   public.listing_claims%rowtype;
  tok text;
begin
  select * into c from public.listing_claims where id = p_claim;
  if not found then return 'unknown'; end if;
  if c.status <> 'started' or c.plan <> 'verified' then return c.status; end if;
  if c.created_at < now() - interval '6 hours' then return 'too_old'; end if;
  if c.sync_nudged_at is not null
     and c.sync_nudged_at > now() - interval '2 minutes' then
    return 'checking';
  end if;
  if (select count(*) from public.listing_claims
       where sync_nudged_at > now() - interval '1 hour') >= 30 then
    return 'busy';
  end if;

  select decrypted_secret into tok
    from vault.decrypted_secrets where name = 'github_actions_token' limit 1;
  if coalesce(tok, '') = '' then return 'no_token'; end if;

  perform net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/stripe_sync.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || tok,
      'Accept', 'application/vnd.github+json',
      'Content-Type', 'application/json',
      'User-Agent', 'nomadmaps-db',
      'X-GitHub-Api-Version', '2022-11-28'));
  update public.listing_claims set sync_nudged_at = now() where id = p_claim;
  return 'checking';
exception when others then
  return 'error';
end $$;

revoke all on function public.payment_returned(uuid) from public;
grant execute on function public.payment_returned(uuid) to anon, authenticated;

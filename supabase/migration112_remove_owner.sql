-- ============================================================
-- Migration 112: take an owner off a space.
-- (Applied automatically by the build; nothing to paste.)
--
-- For a test owner, someone who sold the space, or a claim made by the
-- wrong person. The page itself stays exactly where it is (live, draft
-- or queued); only the owner goes:
--   * the plan goes back to Free, with no owner, no enquiry address,
--     no paid or renewal dates and no Stripe link (Stripe itself is not
--     touched: a live subscription is cancelled in Stripe by hand);
--   * the sync is asked to write the Free fields to the Webflow item
--     (a draft stays a draft; nothing is published);
--   * the owner's claims for the space are closed as 'abandoned', which
--     sends no email;
--   * their unsent and waiting changes are dropped, so nothing is left
--     to review in the control centre;
--   * the Stripe orders for the space are marked 'ignored', so the
--     hourly Stripe check never attaches them again;
--   * their account leaves the Owners group if they run no other space;
--   * a dated line is added to the space's notes.
--
-- remove_owner() does the work; admin_remove_owner() is the app's
-- "Remove owner" button (founders only).
--
-- At the end: the test owner Leonie used on Coastal (Oct 2026) is
-- removed. The Coastal draft in Webflow is kept for a real claim later.
-- ============================================================

create or replace function public.remove_owner(p_venue uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        public.venues%rowtype;
  em       text;
  n_claims int := 0;
  n_drafts int := 0;
  n_orders int := 0;
  n_people int := 0;
begin
  select * into v from public.venues where id = p_venue;
  if not found then
    raise exception 'Space not found.';
  end if;
  em := nullif(lower(trim(coalesce(v.listing_owner_email, ''))), '');

  update public.venues set
    listing_tier              = 'free',
    listing_owner_name        = null,
    listing_owner_email       = null,
    listing_enquiry_email     = null,
    listing_paid_at           = null,
    listing_renews_at         = null,
    stripe_customer_id        = null,
    stripe_subscription_id    = null,
    listing_notes             = concat_ws(E'\n',
                                  nullif(listing_notes, ''),
                                  'Owner ' || coalesce(em, '(no email)')
                                    || ' removed on ' || to_char(now(), 'DD Mon YYYY')
                                    || coalesce('. ' || nullif(trim(p_note), ''), '')),
    listing_sync_requested_at = now(),
    listing_synced_at         = null,
    listing_sync_error        = null
  where id = p_venue;

  -- Their claims for this space: closed, quietly.
  update public.listing_claims
     set status = 'abandoned'
   where venue_id = p_venue
     and status in ('started', 'paid', 'awaiting_approval', 'free_pending', 'free')
     and (em is null or lower(trim(owner_email)) = em);
  get diagnostics n_claims = row_count;

  -- Changes not yet on the page.
  if em is not null then
    delete from public.owner_drafts
     where venue_id = p_venue
       and lower(trim(owner_email)) = em
       and status in ('draft', 'submitted');
    get diagnostics n_drafts = row_count;
  end if;

  -- Payments for this space are never matched to it again.
  update public.stripe_orders
     set status = 'ignored',
         matched_by = 'owner removed ' || to_char(now(), 'DD Mon YYYY')
   where venue_id = p_venue
     and status <> 'ignored';
  get diagnostics n_orders = row_count;

  -- Out of the Owners group, unless they run another space.
  if em is not null and not public.is_owner_email(em) then
    update public.profiles p
       set cohort = null
      from auth.users u
     where u.id = p.id
       and p.cohort = 'owner'
       and lower(trim(u.email)) = em;
    get diagnostics n_people = row_count;
  end if;

  return jsonb_build_object(
    'venue_id', p_venue,
    'name', v.name,
    'removed', em,
    'claims_closed', n_claims,
    'drafts_dropped', n_drafts,
    'orders_ignored', n_orders,
    'left_owners_group', n_people > 0,
    'had_subscription', v.stripe_subscription_id is not null);
end $$;
revoke all on function public.remove_owner(uuid, text) from public, anon, authenticated;

create or replace function public.admin_remove_owner(p_venue uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  return public.remove_owner(p_venue, p_note);
end $$;
revoke all on function public.admin_remove_owner(uuid, text) from public, anon;
grant execute on function public.admin_remove_owner(uuid, text) to authenticated;

-- ------------------------------------------------------------------
-- The Coastal test owner. Everything the test account left behind goes,
-- so the Owners figures, the ideas board and the money card show only
-- real owners. The space and its Webflow draft stay.
-- ------------------------------------------------------------------
do $$
declare
  test_email constant text := 'mofivib235@bitproy.com';
  r record;
begin
  for r in
    select id from public.venues
     where lower(trim(listing_owner_email)) = test_email
       and name ilike '%coastal%'
  loop
    perform public.remove_owner(r.id, 'Test account used by Leonie; page kept as a draft');
  end loop;

  update public.listing_claims
     set status = 'abandoned'
   where lower(trim(owner_email)) = test_email
     and status in ('started', 'paid', 'awaiting_approval', 'free_pending', 'free');

  delete from public.owner_drafts
   where lower(trim(owner_email)) = test_email
     and status in ('draft', 'submitted');
  delete from public.owner_answers where lower(trim(owner_email)) = test_email;
  delete from public.owner_idea_votes where lower(trim(owner_email)) = test_email;
  delete from public.owner_idea_suggestions where lower(trim(owner_email)) = test_email;
  delete from public.owner_billing_events where lower(trim(owner_email)) = test_email;

  update public.stripe_orders
     set status = 'ignored', matched_by = 'test account'
   where lower(trim(email)) = test_email
     and status <> 'ignored';

  if not public.is_owner_email(test_email) then
    update public.profiles p
       set cohort = null
      from auth.users u
     where u.id = p.id
       and p.cohort = 'owner'
       and lower(trim(u.email)) = test_email;
  end if;
end $$;

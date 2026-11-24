-- Migration 353: the Claim plan can say how many spaces claimed after we
-- wrote to them (Jonathan, 24 Nov 2026, on "By type and country": "would
-- it make sense in these columns, to include in a % of % claimed, and
-- claimed as a % of written to. cafes or coworking spaces might have
-- different effectiveness. different countries might have different
-- effectiveness").
--
-- "Written to" on that screen counts only spaces that have NOT claimed,
-- so a rate needs the other half: of the claimed spaces, which had been
-- written to before they claimed. admin_claim_plan() now sends that with
-- each claimed page as wrote_first. Nothing else it returns changes.
--
-- wrote_first is true when a message from us went out before the
-- space's first claim, either to a contact of that space or to another
-- contact with the same address (one company, several spaces), the same
-- rule "written to" follows for unclaimed spaces. Test contacts are
-- left out. A message sent after the claim does not count.

select public.pm_patch_fn('public.admin_claim_plan()',
  $a$jsonb_build_object('kind', v.type, 'country', v.country)$a$,
  $a$jsonb_build_object('kind', v.type, 'country', v.country,
                         'wrote_first', exists (
                           select 1
                             from public.outreach_messages m
                             join public.space_contacts c on c.id = m.contact_id
                            where m.direction = 'out' and m.send_error is null
                              and not coalesce(c.is_test, false)
                              and (c.venue_id = v.id
                                   or (c.email is not null
                                       and (lower(c.email) = lower(btrim(v.listing_owner_email))
                                            or lower(c.email) = any (
                                              select lower(e) from unnest(coalesce(v.contact_emails, '{}')) e))))
                              and m.at < coalesce(
                                    (select min(lc.created_at) from public.listing_claims lc
                                      where lc.venue_id = v.id), now())))$a$,
  $a$'wrote_first'$a$);

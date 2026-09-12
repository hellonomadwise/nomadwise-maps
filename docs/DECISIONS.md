# Pending decisions — Nomad Maps

Everything built so far is live. This file tracks what is deliberately
NOT built or settled yet because it needs a decision first. Work top
to bottom when there is time. Updated 26 July 2026.

## Decisions to take together (Jonathan + Leonie)

1. **Strategy direction.** Growth engine for nomadwise, standalone
   product, or deliberate slow-down. The fresh strategy session is set
   up for this: context brief + Leonie's feedback + the plan PDF, in a
   new conversation on the most capable model. Every other joint
   decision below flows from this one.
2. **Business plan sign-off.** v1.0 is a draft. Read together, change
   what needs changing, sign v1.1. Includes the 100 euro monthly
   payout cap, the joint decision list and the weekly sync rhythm.
3. **Reverse pipeline go/no-go.** New map finds becoming staged
   nomadwise CMS drafts plus the sitemap sheet. Designed, not built.
   Touches nomadwise, so it waits for a joint yes. This is the engine
   behind 999 to 20,000 listings.
4. **Coin values sit-down.** Current reality: new space 50, confirm
   30, WiFi test 100, WiFi login 20, finder bonus 10. The review is
   right that the logic is not visible (a WiFi test pays double a full
   review). Decide the values once; changing them is now a one-line
   config edit and every screen updates, including the in-app "How
   coins work" table.
5. **Naming and logo decision**, with the capitalisation style pass
   across all UI text bundled in so the interface is touched once.
6. **List card redesign** leading with the decision facts (WiFi,
   plugs, hours, noise) and the related "Work now" ranked-list idea.
   Marked "only if continuing", so it follows the direction decision.
7. **Farming caps in code.** Per-user daily submission caps,
   per-space retest cooldowns, and the monthly payout cap enforced in
   code rather than by manual approval alone. The mechanics are clear;
   the numbers (including whether 100 euro/month stands) are the
   decision. Belongs with item 4's coin sit-down, along with the
   open question of whether surfacing a promising place (a card view
   that promotes a pin) should ever earn a reward, and if so what a
   non-farmable version looks like.
8. **After a WiFi test, return to the space page** with the new
   result showing, instead of the map. Marked "only if continuing",
   so it follows the direction decision.
9. **Pin clustering.** Needed before any bulk expansion of visible
   pins (e.g. promoting unscreened places or another import). Gated on
   those decisions, not urgent today.

## Jonathan's own list (small, mostly minutes each)

10. **Payout cap enforcement in code.** Parked on request. The plan
   promises payouts pause at 100 euro/month; making it code (about an
   hour) should happen before any wider launch if coins stay on.
11. **Gemini API key** (free, aistudio.google.com, 2 minutes) to switch
   on AI photo pre-screening, the fast fix for the stock-photo
   problem at 865-venue scale.
12. **Two-factor auth** on Google, Supabase and GitHub for both
    founders. The plan committed to this; it is the single best item
    in the whole risk register.
13. **84 unmatched listings** review sheet in Google Drive, a coffee
    session for either founder; confirmed-closed ones are also
    nomadwise cleanup candidates.
14. **Professional legal read of the terms** before the map gets big.
    The plain-language version is live and solid for beta. Updated
    1 August after the terms review: Nomadwise Ltd is now named in
    the terms, cash-out flow and menu; contributors explicitly keep
    photo ownership and grant a licence; a new account-security
    section covers hacked accounts, recovery and payouts going only
    to the account holder's own payment method.
14b. **Account management page** (change email, delete account from
    inside the app, later payment details). From the terms review;
    needed before public launch, not for beta. Sign-in is Google
    only, so there is no password to manage.
15. **Custom SMTP sender** before wider launch (sign-in emails
    currently come from the default sender).
16. **Google billing: now urgent, not October.** The trial credit is
    under 50 dollars (Google's mail, 31 July). Upgrade to a paid
    account soon: it costs nothing by itself, keeps the remaining
    credit, and unlocks the quota caps and budget alerts. Set a
    budget alert (e.g. 25 euro/month) the same day. The 31 July fix
    moved all credit-spending data jobs to one nightly run instead of
    every build, which was the main leak.

## Standing rules while these wait

Nothing public without both founders. Nothing touches nomadwise
content, data or SEO without a joint yes. Anything reversible stays
reversible.

## Shipped: the one-to-one link with nomadwise.io (12 September 2026)

Both founders agreed the first step of the Listings Engine is a
reliable link between every Nomad Maps venue and its nomadwise.io
page, in both directions, before any business features are built.

What is in place:

- The Webflow Coworking collection has a "Google Place ID" field,
  filled for 998 of 999 listings (the odd one out, Merchants Lane, is
  permanently closed: archived, with a redirect to its city page).
  The place id is the shared key on both sides; nothing else is.
- Migration 49 adds venues.webflow_slug, website_status and
  website_synced_at. The nightly job (scripts/webflow_sync.py, run by
  enrich.yml, token WEBFLOW_API_TOKEN) reads the live Webflow
  collection, matches on the place id and keeps those fields current.
  Its report lands on the sync-reports branch.
- Field ownership rule, so the two systems never fight: Webflow wins
  on words (name, type, website, instagram, neighbourhood, Google
  snapshots, fallback hours, the yes/no facts); the community wins
  on measurements (a venue's WiFi speed is never overwritten once a
  nomad has tested it there; photos and confirmations are untouched).
- The space page in the app shows "See the full guide on nomadwise.io"
  while the page is live; admins see each space's website status.
- Release control is Webflow's own per-item sitemap switch plus the
  existing nofollow field. No custom sitemap is needed.

Not built yet (next phases): creating Webflow items from the app for
new finds, the release switch inside the admin screen, business
accounts and paid claims, the monthly stats email. The optional
"Open in Nomad Maps" button on the website is a joint decision.

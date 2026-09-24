# Nomad Maps: handoff note

Written 22 September 2026, refreshed 24 September, by the "Nomadwise
Maps mobile app" chat, for any other chat or person picking up the
project. Everything below is
also in the repository (`docs/`), which is the source of truth; this
note is the map of it.

Nothing secret is in this note. Keys live only in GitHub's secret
store and the Supabase dashboard. Do not paste the service role key
into any chat; anyone needing to read the database should be given
the Supabase dashboard in a browser, or a read-only key made for the
purpose.

## What it is

Nomad Maps (nomadmaps.io) is the app and control centre behind
nomadwise.io's coworking directory. Nomads use it to find and review
cafes and coworking spaces; the founders use it to run the directory:
publish pages to Webflow, keep the sitemap right, sell and manage
Verified listings, and answer booking requests. It powers the
1,033 listing pages on nomadwise.io.

## What it is built with

- **App:** Flutter (Dart), built for the web as a PWA and also as an
  Android APK. Hosted on GitHub Pages at nomadmaps.io. Public doors
  are query parameters, not routes: `?claim` (owner claim flow),
  `?claimed` (return from Stripe), `?enquire=<slug>` (booking request
  for a Verified page). Everything else is the map.
- **Database:** Supabase (Postgres) project `xclqfbuwrijpwtgbvrim`,
  `https://xclqfbuwrijpwtgbvrim.supabase.co`. The app talks to it with
  the public anon key through `supabase_flutter`; every table has row
  level security; anything sensitive goes through `security definer`
  functions (RPCs); founders are recognised by `public.is_admin()`.
- **Jobs:** GitHub Actions in `.github/workflows/`. `build.yml` builds
  and deploys on every push and applies new database migrations
  (`scripts/apply_migrations.py`, runner installed by migration 42; a
  failed migration is reported in the step log, and the step is
  `continue-on-error`, so a green build does not prove the migration
  applied). `enrich.yml` runs nightly at 04:23 UTC (Google details
  refresh, photo links, photo suggestions). `webflow_push.yml` writes
  pages to Webflow (triggered by the database via `sync_nudges`).
  `stripe_sync.yml` reads Stripe hourly. The `*_audit.yml` and
  `booking_lodging_detect.yml` are occasional data checks.
- **Website:** Webflow site `64b6780f84d27e4bfd91f236`. Collections:
  Coworking `65fa86d0e0379bf78d52448d` (at the 60-field limit; the
  Verified fields reuse old booking-engine fields, see
  `docs/WEBFLOW_VERIFIED_SETUP.md`), Regions `660a67b0318bdc118b67a3e5`
  (`/region/<slug>`), Locations `65fa86d0e0379bf78d52451c`
  (`/locations/<slug>`), Countries `660a654b9f17e25bfb2500bd`
  (`/country/<slug>`).
- **Payments:** Stripe. Product "Nomadwise Verified", EUR 99 a year,
  payment link in `app/lib/config.dart` (`stripeVerifiedLink`). The
  link carries `client_reference_id` = a venue id or a claim id, so a
  payment always knows whose it is. A restricted key lives in the
  GitHub secret `STRIPE_API_KEY`.
- **Phone alerts:** `public.notify_phone(title, message, tags)` posts
  to ntfy.sh (topic in migration 25) via `pg_net`. Used for claims,
  payments, new submissions, and now claim page visits.
- **Other tools:** Google Places API (New) for details, photos and the
  add-a-space search; PostHog for analytics; Google Maps for the map.
  Resend (email) is chosen but not yet set up.

## Where things are in the repository

- `app/lib/screens/map_screen.dart` the map, list and venue cards.
- `app/lib/screens/venue_detail.dart` a venue's page in the app.
- `app/lib/screens/website_screen.dart` the control centre (inbox,
  drafts, released, sitemap, hidden, closed, paid listings, booking
  requests, region and location creators).
- `app/lib/screens/claim_screen.dart` the owner claim flow (3 steps).
- `app/lib/screens/enquiry_screen.dart` the booking request form.
- `app/lib/services/supabase_service.dart` every database call.
- `app/lib/services/places_service.dart` Google Places.
- `scripts/` the jobs; `supabase/` every migration, numbered, applied
  once each by the build; `docs/` the decisions and how-tos.

## Tables (all in `public`)

Core: `venues` (one row per space; Google snapshot in `g_details`,
plain photo links in `google_photo_urls`, Webflow ids and slugs,
`website_status`, listing plan fields `listing_tier`, owner and
enquiry emails, Stripe ids), `profiles`, `submissions` (reviews and
new spaces from nomads), `venue_wifi`, `venue_networks`,
`photo_picks`, `photo_embeddings`, `feedback`, `coin_ledger`,
`euro_ledger`, `app_events`, `visitor_summaries`, `team_devices`.

Discovery: `discovered_places` (Google results cached per area),
`city_sweeps`, `sweep_queue`.

Website: `webflow_regions`, `webflow_locations`, `webflow_countries`
(each with `first_seen_at`, `source` app or webflow,
`sitemap_tracked`, `sitemap_added_at`), `taxonomy_requests`,
`sync_nudges`, `sync_settings`.

Money and owners: `stripe_orders` (every Stripe checkout, matched to a
venue or left for matching), `listing_claims` (a claim from the form;
statuses started, paid, awaiting_approval, rejected, abandoned),
`claim_visits` (every opening of the claim page), `enquiries`
(booking requests).

Housekeeping: `schema_migrations`.

Key RPCs: `claim_search`, `start_claim`, `claim_paid`, `apply_claim`,
`approve_claim`, `reject_claim`, `abandon_claim`, `claim_opened`,
`report_stale_photos`, `cache_google_photos`, `notify_phone`,
`apply_migration`, `is_admin`.

## What is built and live

- The map and list, reviews, WiFi tests, coins, photos, submissions.
- The control centre: inbox of new spaces, drafts, published pages,
  sitemap log (listings, regions, locations, countries), hidden and
  closed places, region and location creators, paid listings.
- One-to-one sync with nomadwise.io: the database asks GitHub to
  push, pages are written to Webflow, closed places are retired.
- Verified listings end to end: the claim flow at `?claim`
  (find space or add from Google Maps; about you incl. optional
  website and Instagram; pay through Stripe), the hourly Stripe read
  that turns payments into plans, the approval hold for paid claims
  on pages already on the site (card in Paid listings with Approve
  and Reject), the phone pings, and the claim page visit log with the
  page the visitor came from.
- Booking requests: the form at `?enquire=<slug>` writes to
  `enquiries`; the email to the owner waits on Resend.
- Google photos self-heal (22 Sep): names expire after about four
  weeks; the nightly refresh is now every 21 days and resolves links
  at refresh; the app fetches fresh names when a photo fails.
- Phone pings verified end to end on 22 Sep (ntfy topic, and the
  database's `notify_phone()` through `pg_net`). Earlier "no ping"
  reports came from migrations 70 to 73 not yet being applied.
- 23 Sep: the Closed tab filters temporary vs closed for good, with a
  tag on each card. An approval now always starts the push run
  (migration 76; the old two-minute throttle dropped it) and the
  "Approved, being created" section has a "Start the run now" button.
  Opening hours and rating are fetched from Google before a page is
  built, and a nightly pass repairs control-centre pages that went out
  without them (`hours_backfilled` in the enrich log). The share card
  lost its coin tag and shows green pills per upside; the share
  message links to the space (`?place=<google place id>&at=lat,lng,16`).
- PostHog dashboard "Directory: new pages vs existing" (see
  `docs/PAGE_TRACKER.md`): new = first ever page view on or after
  13 Sep 2026; no job, no key.

## In progress or waiting on a person

- **Webflow Designer work (Jonathan):** done on 22 Sep: Verified
  badge on the Coworking template, "Is this your business?" repointed
  to the claim form with the site-wide snippet, the card ribbon
  renamed Verified, and the list sort on the Region and Location
  templates set to Listing Rank Z to A, then WiFi rating, then Google
  reviews. Still to do: the two booking buttons (free: "Contact the
  space" linking out; Verified: request form), which wait on Resend.
- **Resend:** account, DNS, API key in the Supabase Vault as
  `resend_api_key`. Until then no email leaves the system (owner
  "your page is live" email, booking request delivery).
- **Rotation inside the Verified group:** built 22 Sep
  (`rotate_verified()` in the nightly sync); first run 04:23 UTC on
  23 Sep.
- **Contact click counting** on free pages, for the upgrade email.
- **Owner account** ("Owner account" and "Manage my listing" to
  owners, never "members area"): free tier with locked Verified rows,
  owner page for photos, description, prices, hours, all reviewed
  before going live. Next after Webflow and Resend.

## How to write for this project (learned in chat, not obvious from code)

- No em dashes anywhere. Plain sentences, warm, no hype words.
- Never name AI products: say "Google and AI assistants", "search
  engines and AI assistants", "Found by Google and AI".
- "Owner account" and "Manage my listing" to owners; "members area"
  is internal only. Never promise a publication timeframe, never
  "under 2 euro a week" or "one booking covers it", never analytics
  or page views as part of Verified.
- Verified is exactly five things (badge, above every free listing,
  booking requests to inbox, own photos and words, advert slot).
- Jonathan is not a coder: explain plainly, one decision at a time,
  say what a change does before how. Leonie reviews everything owner
  facing and pushes back on anything owners could game.
- Wording lives in the app, the comparison artifact, the flowchart,
  the memo, the Webflow page copy and DECISIONS.md: change all of
  them together.

## Pending on 24 September

- Jonathan uploads the zip with migration 76, website_screen,
  supabase_service, webflow_sync, story_card, venue_detail,
  PAGE_TRACKER.md and .gitignore; then check the first
  `hours_backfilled` run and the `?place=` share link on a real space.
- Webflow (Jonathan, from `docs/GET_LISTED_PAGE_REPLACE.md`): the Get
  listed page text; redirects for /pricing, the three "add my
  business" forms and /sign-up to it; owner links in Navbar and
  Footer; Country template sort if it lists spaces.
- Resend (account, DNS, Vault key `resend_api_key`), then owner emails
  and the two booking buttons; contact-click counting; owner account;
  free-claim ownership check; "temporarily closed until" toggle;
  owner-supplied facts surviving refresh; change log.
- Optional: make the build fail visibly when a migration fails; tidy
  the Webflow body code; delete the stray `claim_screen_1.dart`,
  top-level `stripe_sync.py` and `__pycache__` on GitHub.
- Attaching the repository to a Claude task (GitHub app installed for
  hellonomadwise/nomadwise-maps) lets the chat push to a branch and
  open pull requests, replacing zip uploads with a review step.

## Decisions that shape everything (full list in `docs/DECISIONS.md`)

- Listing is free and stays free. Verified (EUR 99 a year) is five
  things: the badge, placement above every free listing, booking
  requests to the owner's inbox, their own photos and words, their
  event or offer in the advert slot. No analytics promised.
- Pay first, details after. No account needed to claim and pay.
- No publication timeframe is ever promised; listings join a queue.
- Every owner change is reviewed before it goes live, on any tier.
- A paid claim on a page already on the site waits for approval;
  a new space goes into the publishing queue. Rejection = full refund
  in Stripe, page untouched, reason kept.
- Order inside the Verified group rotates nightly; nothing
  owner-supplied (WiFi speed, ratings) decides position.
- Free listings get a "Contact the space" button, not a request form.
- "Page built to be found by Google and AI assistants" is about page
  structure, not the description.
- Supabase refuses an `update` without a `where`; every migration
  must carry one.
- The repository cannot be pushed from Cowork sessions (proxy); files
  are delivered as zips and uploaded through the GitHub website.

## Documents for Leonie

- Free or Verified comparison: claude.ai/artifact/1QaYhX2aWA1eWkLtBsM5cX
- Claim to Live flowchart: claude.ai/artifact/FFXsuPQWktszUdXixHeX9c
- Status deck: claude.ai/artifact/2xYUednBeAemjCW1JmkRba
- Her review card in Notion: "Nomadwise Maps Review" on the Task Board.

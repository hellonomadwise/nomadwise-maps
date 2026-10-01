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

Reverse direction (same day): founders queue a space for the site
from its page in the app ("Queue for the site", admins only; needs a
Google match). The nightly sync turns each queued space into a Webflow
DRAFT listing, attached to the matching Country, Region and Location,
with every fact the app knows and an Images entry holding the approved
community photos (Google's photos are never copied to the site). It
stays a draft until a founder adds words and pictures and publishes in
Webflow; the next night it reads as released. A space whose city or
neighbourhood matches no Webflow Location stays queued and is listed
under needs_location in the sync report. Decided: only queued spaces go
to the site, never every approved one.

Not built yet (next phases): business accounts and paid claims, the
monthly stats email, a live read of Webflow's sitemap flag (the sync
uses a snapshot from 12 September until the endpoint is confirmed).
The optional "Open in Nomad Maps" button on the website is a joint
decision.

## Shipped: the nomadwise.io control centre (13 September 2026)

An admin screen in the app ("nomadwise.io" in the menu, phone and
laptop) that works like an inbox: everything needing a decision about
the site sits in one list, each card has one or two actions, acting on
it moves it out, and an empty inbox says so. Tabs: Inbox, Drafts,
Released, Sitemap.

- Queueing no longer creates the Webflow draft straight away. The
  nightly sync PREPARES a proposal first (slug, Region, Location,
  Country, hours, facts, photo count; migration 50, venues.
  website_prepared) and the inbox shows it. The founder can change the
  slug there, the last chance before it is fixed, and taps Approve;
  the next run creates the draft and its Images entry with exactly
  that slug. Decided: no slug renames after creation, ever (they need
  redirects), so the slug is seen before it is born.
- A space whose city matches no Region lands in "Needs a Region" with
  a dropdown of the site's Regions (copied nightly into
  webflow_regions). Copenhagen is a Region, not a Location; pages may
  have a Region only.
- Every inbox card opens the full space page (tap the name) and has
  an Edit button: name, type, neighbourhood, city, links, WiFi, the
  yes/no facts and opening hours, saved straight to the venue. A
  prepared proposal stays approvable after an edit because the page
  is built from the latest details on the night it is created.
- "Not for the site" hides a space from the inbox without changing
  anything else, and records why (migration 51: a reason from a fixed
  list plus an optional note). Hidden spaces stay listed at the bottom
  of the inbox with their reason and a Bring back button, so it is
  always clear why something is on Nomad Maps but not on the site.
- Removing a space from the queue returns it to New spaces; it never
  hides it.
- Hard rule (14 Sep): no page is ever created in Webflow without a
  Country and a Region, because the slug is built from the Region and
  cannot be changed afterwards without a redirect. The app shows the
  Region and the expected slug the moment a space is queued; a queued
  space with no Region sits in "Needs a region" and cannot be prepared
  or approved until one is picked. The sync refuses to create anyway
  if either is missing (belt and braces).
- The Location (neighbourhood page) is optional and nuanced: the
  sync's match is shown as a guess and the founder confirms, changes
  or drops it before approving (migration 52, website_location_override;
  Locations copied nightly into webflow_locations).
- Sitemap tab: released pages missing from the custom sitemap become
  the exact <url> blocks to paste (priority 0.80, lastmod always dated
  yesterday with a randomised time of day), with a "mark as added"
  step.
- Opening hours written to Webflow use a plain hyphen with spaces
  ("8:00 AM - 6:00 PM"), never Google's en dash. Slugs fold accents
  (pa, not p, for "på").
- The existing Kaffebaren på Amager draft keeps its slug
  (denmark-copenhagen-kaffebaren-p-amager); the fix is for future
  spaces only.

- Slug rule (14 Sep): always country-region-name, for example
  portugal-lisbon-lacs-anjos, never the Region's own slug (some Regions
  carry the country in theirs, some do not). The country is stored on
  the venue (migration 53), prefilled from Google's address, editable
  in the control centre, and shown on every card.
- Photos before Webflow (14 Sep): a listing cannot be approved with
  fewer than three pictures. The founder pastes up to five image links
  in the control centre (the long-standing method: copy the image
  address from the place's Google page); they are stored on the venue
  (migration 54, website_photos) and the sync puts them, then any
  approved community photos, into the Images entry as the draft is
  created. The sync refuses to create with fewer than three.
- Taxonomy is the founders' (16 Sep): in the control centre the
  Region and Location are chosen from the site's own lists (copied
  nightly), never typed; what the nomad wrote and what Google says are
  shown as hints. "Needs a new Region/Location" records the wanted
  name (migration 55) and parks the space under Blocked; when the
  founder creates it in Webflow with that exact name, the sync links
  the space to it. The app never creates Regions or Locations.
- Sitemap truth (16 Sep): the nightly sync reads the live custom
  sitemap and sets or clears venues.sitemap_added_at to match, so the
  Sitemap tab only ever lists pages that really are missing, and a
  page dropped from the sitemap shows up again.
- Quick lane (14 Sep): webflow_push.yml runs the sync in --push-only
  mode every ten minutes, so a queued space has its proposal within
  minutes and an approved one its Webflow draft within minutes. The
  nightly run keeps the full pull and the Region/Location copies.
  Approving locks the slug: it is used exactly, and if it is taken the
  space comes back as Blocked (slug taken) rather than being renamed.

Still to come: moderation of business-written descriptions (a
"words waiting for review" tab in the same inbox), the live read of
Webflow's sitemap flag, and the closed-listings cleanup.

## City and area pickers on the review form (Sep 2026)

The review form shows a City field (the nomadwise.io Region the
space matched, spelled the site's way) and a Neighbourhood field
that opens a searchable list of the site's areas for that city.
Both are searchable bottom sheets, not chip rows: London alone has
dozens of areas. The nomad can pick a city page by hand when Google's
city matched nothing or matched wrongly, keep Google's city, and
type an area that is not on the site yet. Neither picker creates a
Region or Location in Webflow; unknown names reach the founders
through the inbox as before. A verified review now also sets the
venue's city (migration 56), so older "Lisboa" records become
"Lisbon" the next time a nomad reviews them.

## The site's Country beats Google's (Sep 2026)

For the slug and the inbox cards, the country comes from what the
founder typed, else the Webflow Region's Country, else Google's
address. Google says "United Kingdom" while the site files London
under England, Edinburgh under Scotland and Cardiff under Wales, so
Google's word can only be a fallback when no Region matched. Picking
a Region in Edit fills the Country field from it, and a note offers
the site's Country whenever the typed one differs.

## "No laptops" spaces in the inbox (Sep 2026)

A New space whose nomads answered "no" to laptops is almost always
not for the site. The card shows a "No laptops" chip and a note, and
its main button becomes a one-tap "Not a place to work", which files
it under Not for the site with the reason "Not really a place to
work from" and no dialog. Queueing stays possible ("Queue anyway")
because the founder, not the flag, decides.

## Published drafts are noticed within minutes (Sep 2026)

The ten-minute push run also reads the live item for every venue in
published_hidden (one small request each). A live, non-draft item
marks the venue released, so its sitemap entry appears under Sitemap
within minutes of the founder publishing in Webflow, not the next
morning. The nightly pull keeps the last word (sitemap flag,
archived, taken down). The Released chip moved to the end of the
row: it is an archive to look things up in, not a step with work.
The founder can also say "Published, add to sitemap" on a draft's
card: the venue is marked released at once and the Sitemap chip
opens, so a batch of pages can be published and added to the sitemap
in one sitting. The nightly read still corrects a page that is not
actually live.

## The database starts the push run (Sep 2026)

GitHub's ten-minute schedule turned out to run every few hours in
practice (23 runs in two days). Queue, approve and edits while queued
now nudge GitHub directly: a venues trigger (migration 57) calls the
workflow_dispatch API through pg_net, at most once every two minutes,
using a fine-grained GitHub token kept in Supabase Vault under
github_actions_token. Without the secret the trigger is a no-op and
the schedule remains the fallback. The app's promise of "within about
ten minutes" holds again, usually within two.

## Photo suggestions (Sep 2026)

The rule "Google Places photos are never copied to Webflow" is
relaxed to "never without the founder's approval". Jonathan already
copied Google's image links by hand (right-click, Copy image address);
scripts/photo_suggest.py now does the equivalent: it lists a queued
space's Google photos, resolves each to the same plain
lh3.googleusercontent.com link, adds the approved community photos,
and scores every candidate with CLIP against a written brief. The
brief says what a listing photo is for: the room, the seating, the
front, people working, a coffee with the room behind it; and what to
avoid: food and drink close-ups, pastry displays, menus, selfies,
logos. The best five go on the page's photos flagged as suggested,
the card says so, and Approve is still the founder's gate; the
photos picker shows the whole scored grid to swap any of them.
At Approve the app records what was kept and skipped; the nightly
run turns that into a taste vector (photo_taste) that nudges future
scores. Scoring runs inside GitHub Actions on open weights (no API);
Google costs are one Details and up to ten Photo media calls per
queued space, within the free tiers at current volume. If the model
cannot be loaded, Google's own photo order stands in.

## Google photos are paid for once, then free (Sep 2026)

Every Google photo the app showed went through Google's billed media
endpoint on each load (map cards, space pages, the review form), and
at 1,000 spaces a month that was the largest Google line. Now each
photo is resolved once to its plain image link and kept on the venue
(google_photo_urls, migration 59); PlacesService.photoUrl uses the
stored link whenever it has one, so a photo is billed at most once
in its life. The nightly job resolves the backlog 150 venues a night,
the review form resolves a new place's six reference photos on first
open and saves them with the venue, and the website photo suggestions
take names from the nightly snapshot instead of their own Details
call and reuse the stored links, so a queued space usually costs no
Google calls at all. Estimated at 1,000 spaces a month: about $100
instead of about $210.

## Backlog of photo links: off for now (Sep 2026)

The nightly resolving of existing venues' photo links exists to stop
paying per photo view once nomads use the app. Today the app is used
by the founders alone and the aim is listing throughput into
nomadwise.io, so it is switched off (RESOLVE_PER_NIGHT = 0) and the
free photo calls are kept for the website pipeline. The first night
already covered 150 venues. Turn it to 30 (free, slow) or 150 (about
$20, five nights) when the app gets real traffic.

## Five photos, widening the pool (Sep 2026)

The target is five usable photos per page. The snapshot holds six
Google photo names; when fewer than five of them pass the brief, the
script fetches the place's full list (up to ten, one Details call)
and scores the extra ones too. If there are still fewer than five
good ones, the five are filled with the best of the weak ones,
flagged "weak", and the card says "5 suggested, N weak (few clear
shots on Google). Check them" so the founder looks before approving.
Google's API exposes at most ten photos per place; beyond that the
founder pastes links by hand as before.

## Drafts checked and published from the app (Sep 2026)

Checking that every Webflow listing and its Images entry match was
the last step done by eye. The push run now reads each draft back:
listing and Images entry point at each other, the slug is the one
approved, Region and Country are set, the Google Place ID matches
the app, at least three photos were accepted by Webflow, nothing is
archived. The verdict (website_prepared.webflow_check) shows on the
card in In Webflow, green or with the list of problems. A clean
draft gets a "Publish on nomadwise.io" button: the run re-checks,
stages both items and publishes them live through the CMS API
(Images first), then marks the venue released so the sitemap entry
follows. "I published it in Webflow" remains for pages published by
hand. Migration 61 adds website_publish_requested_at and teaches the
nudge trigger to wake the run for it.

## Region and Location creators (Sep 2026)

The rule "the app never creates Regions or Locations in Webflow"
becomes "only from a form the founder filled in". Two creators live
in the control centre (the pin icon in the header, and the "needs a
new one" entries in Edit's pickers, pre-filled from the space). A
request (taxonomy_requests, migration 62) wakes the push run, which
builds the item the way the existing ones are built: Region = "City,
Country", label, slug country-city, Country link, category label, H2
header, optional description, map centre and zoom, turned on, logo
as OpenGraph image; Location = "Area, City", label, slug
country-city-area, Country and Region links (both fields), filter id,
category label, H2, turned on. It publishes the item, appends a new
Location to its Region's Locations list and republishes the Region,
copies the item into the app's pickers, and the spaces waiting for
it by name are linked in the same run. Countries stay Webflow-only.

## Region and Location slug conventions, verified (Sep 2026)

Checked against every item in Webflow on 18 Sep 2026. Regions: 133
of 160 live ones are country-city (england-london, denmark-copenhagen);
15 early ones (April to July 2024) are bare (lisbon, bangkok, bali);
the United States and Goa use country-state-city
(united-states-colorado-denver, india-goa-anjuna). Locations:
country-city-area throughout, including under the bare legacy
Regions (portugal-lisbon-baixa sits under the Region whose own slug
is lisbon). Apostrophes vanish rather than become hyphens
(diocletians-palace, riva-darno); slugify now does the same
everywhere. The creators pre-fill these conventions (state added
for the US and India when Google supplies it), show up to three
existing slugs from the same country or Region as examples, and let
the founder edit the slug before creating; the sync uses the slug
exactly, refusing a duplicate.

## City centre found from name and Country (Sep 2026)

The Region form used to need the map centre typed by hand, looked up
on a geocoding website with the country added so the right Lancaster
came back. The form now does that itself: once the city name and
Country are in, it asks Google for "City, Country" (one Text Search
call, inside the free monthly allowance at this volume) and fills
latitude and longitude, showing the address Google resolved so the
founder can see it is the right place. A space's own coordinates are
no longer used as the city centre. Coordinates typed by hand are
kept; "Find city centre" replaces them on purpose.

## Pickers refreshed from Webflow on demand (Sep 2026)

Ulm and its two Locations appeared in Webflow without going through
the app's creators, so the pickers, which are a copy, did not have
them until the nightly copy. Two changes: every sync run that gets
past "nothing to do" now copies the site's Regions and Locations
into the app (a few hundred rows, cheap), and the control centre's
pin menu has "Refresh Regions and Locations from Webflow", which
files a request of kind refresh (migration 63) that wakes the sync
for that copy alone. Items made in Webflow by hand are usable in the
app a minute or two later.

## Region form shows the map it will publish (Sep 2026)

Under the coordinates the form shows a live Google map at exactly
the centre and zoom the city page will use, with a pin on the
centre. It follows the fields (found, typed, or zoom edited), and
the other way round: drag or zoom the preview and "Use this view"
writes that centre and zoom into the fields. The full-page map on
the site opens two zoom levels closer, as the existing Regions do.
A handful of map loads a month, inside Google's free allowance.

## Closed places and retiring their pages (Sep 2026)

Google's business status is now recorded for every venue: the monthly
snapshot carries it at no extra cost, and a status-only check (one
cheap field, inside the free allowance) covers every page on the site
about once a month, so a closure is noticed within a month of Google
knowing. A place seen as closed for good leaves the Nomad Maps map at
once. The control centre gets a Closed section between Sitemap and
Not for the site: each card says what Google reports and when it was
first seen, with two answers. "Still open" keeps everything and asks
again only if the status changes. "Retire the page" asks the push run
to take the listing and its Images entry off the live site, archive
both, release the slug (the archived item is renamed closed-<slug>)
and add a 301 from /coworking/<slug> to the city page, recorded on
the card. Two steps stay with the founder because they touch the
whole site: removing the address from the custom sitemap and
publishing the site so the redirect goes live; the card waits for
that tick. Retired is a website status of its own and the nightly
pull leaves it alone. Migration 64.

## Food photos: a hard rule (Sep 2026)

The learned taste let a few food close-ups through. The brief now
names food close-ups separately (plates, bowls, cake slices, latte
art, display-case close-ups); a photo with 30 percent or more belief
on those is never "good" and sinks to the bottom, whatever the taste
bonus. Food is welcome only as an overview of the counter with the
shop in view, or a coffee on a table with the room behind it. The
brief carries a version number; spaces still waiting for approval are
rescored when it changes.

## Listing plans: free or Verified (Sep 2026)

The business model, decided 19 and 20 Sep: one paid tier, Verified,
99 EUR a year, annual through Stripe; Featured parked. What Verified
buys is visibility and leads, never a booking engine (the earlier
Webflow booking engine went to Stripe, took a euro a booking on day
passes, and was retired). The app is the source of truth: a Listing
plan (tier, owner, enquiry email, paid and renewal dates) lives on
the venue (migration 65) and the push run writes four Webflow fields
and republishes the page. The Coworking collection is at Webflow's
60-field limit, so the old booking-engine fields were renamed rather
than added: Premium Member is now Verified, Booking Engine is
Enquiries On, Payment Model is Listing Rank ("1"/"0", text so the
Designer can sort it), Coworking Space Email is Enquiry Email. The
Request a booking button links to Nomad Maps with the listing's slug
via a few lines of custom code (no field needed). The nightly pull
copies the Verified switch back so legacy premium pages show up in
the Paid listings section until they get a plan. Designer steps:
docs/WEBFLOW_VERIFIED_SETUP.md; page copy: docs/GET_LISTED_PAGE.md.

## Booking requests (Sep 2026)

Verified pages get a Request a booking button that opens
nomadmaps.io/?enquire=<slug>: one screen, no account, no payment
(the founders retired a real booking engine; the value is the lead).
The request is stored (migration 66, table enquiries, public insert
with a rate guard of five an hour per address and twenty per
listing, plus a honeypot in the form) and a trigger emails it through
Resend to the listing's enquiry address, copying hello@nomadwise.io,
reply-to set to the nomad. The Resend key lives in Vault as
resend_api_key; until it exists a request is kept with status failed
and the reason, the founders get the usual phone ping, and the Paid
listings card offers Re-send. The card also counts requests, which
is the number the renewal conversation is built on. PostHog gets
enquiry_opened and enquiry_sent.

## Selling Verified from the app (Sep 2026)

The Stripe payment link (product "Verified listing on nomadwise.io",
99 EUR a year) lives in the app as a constant. Every space's Listing
plan page, while the space is free, offers "Copy payment link" (the
link with the space's id as Stripe's client reference and the owner's
email pre-filled when known, so the payment attaches to the listing
on its own once the webhook exists) and "Copy offer email" (the
house-voice offer with the name, city, page and that link filled in).
New spaces and released pages both reach the plan page, so a "list
us" request is answered in three taps.

## Payments become plans by reading Stripe (Sep 2026)

No webhook endpoint: scripts/stripe_sync.py reads Stripe with a
restricted read-only key at the end of every push run and hourly, so
it lives inside the existing GitHub Actions and Supabase set-up and
needs one GitHub secret. Paid subscription checkouts are recorded in
stripe_orders (migration 67) and matched to a space by the id the
app's payment link carries, then the owner's email, then a
nomadwise.io link the buyer typed; a match sets the plan and queues
a space that is not on the site yet; no match waits at the top of
Paid listings with an Attach button (search every space by name) or
Ignore. Subscriptions are re-read each run: renewal dates refreshed,
cancelled or unpaid ones back to free. Latency is up to an hour,
which the three-working-day promise absorbs.

## Owners claim their own listing (Sep 2026)

A payment must never arrive without us knowing whose it is. Every
payment link therefore carries an id: the space's, when a founder
sends it from the control centre, or a claim's, when the owner came
on their own through nomadmaps.io/?claim. The bare link stays a
supported path but is now the exception rather than the norm, and
two Stripe custom fields (space name, nomadwise.io link) let even
that case name and often match itself.

The claim flow is three steps and has no account and no password:
find your space (the directory first, Google Maps second, which
hands us a real place id so photos, hours and rating fill themselves
in), who you are, then pay. Paying is the proof of ownership; a
password would only be a second thing to lose. The claim is written
to listing_claims (migration 68) before Stripe is reached, so an
abandoned claim is a warm lead with a phone ping rather than a lost
visitor, and nothing an unpaid stranger types ever reaches the
venues table — a brand-new space becomes a venue row only inside
claim_paid(), once the money has landed.

Details are collected after payment, not before. A long form in
front of the card loses people who would have paid; a customer who
has already paid fills one in. What the page needs on day one
(address, coordinates, hours, photos) comes from Google anyway, so
the listing is publishable without the owner typing anything.

No publication date is promised (decided with Leonie, 21 Sep 2026).
A space already on the site needs no review at all and its badge goes
on at the next push. A new one joins the publishing queue with its
Google details already filled in, and the owner is told it is in the
queue and that we email them when the page is live. Selling a
priority position is an open question, deliberately parked: it is
easier to add later than to withdraw a promise already made.

## Not yet: the private owner page

Photos, description, prices and hours from the owner are still to
build: a long secret in the address rather than a password, emailed
after payment, with submissions going through the same review as
everything else. Until then those details come by email and go in
through the control centre.

## Directory pages in the sitemap tab (Sep 2026)

The Sitemap section now covers three kinds of page, not one: the
listings (/coworking/<slug>), the region pages (/region/<slug>) and
the location pages (/locations/<slug>), each with its own chip and
count. A region or location created in Webflow and never added to the
custom sitemap earns nothing, and those pages rank for a whole city or
area, so one of them missing costs more than a missing listing does.

The mechanism is the one that already worked: webflow_regions and
webflow_locations gain sitemap_added_at (migration 69), the nightly
read of the live sitemap in webflow_sync.py marks and unmarks them,
and the tab generates the same <url> blocks to paste.

But a diff against everything that exists treats a page made two
years ago the same as one made yesterday, and the work is not
"everything ever missed", it is "these were set up recently, are
they in yet". So migration 70 turns the list into a log: every
region, location and country the sync sees for the first time from
now on is recorded with when it appeared and where it came from (the
app's creator, or made by hand in Webflow), newest first, and stays
on the list until its entry exists. Everything older is marked
untracked and never appears, so the log starts clean. Country pages
join the list for the same reason the others did.

The one-off sweep of pages quietly missed before the log began is a
separate job, deliberately not done now. When it is wanted it is one
statement per table — set sitemap_tracked = true — and the nightly
read does the rest.


## Pay first stands, against the concept's account gate (Sep 2026)

The Nomadwise For Spaces concept put account creation and an ownership
review in front of the card. Rejected, after discussion. A long form
before payment loses people who would have paid, and an ownership
queue is manual work on every single sale, which is the opposite of
reducing the founders' job to reviewing a prepared queue.

A card payment is reasonable evidence of ownership and a refund undoes
a mistake. So an unclaimed space is claimed and paid for in one go,
with no account and no review; a check is required only where a space
is already claimed or something looks wrong. Sign-in comes later, as a
way to manage an existing membership, never as a gate in front of the
card.

## Wording owners see (21 Sep, Leonie's review of the comparison)

- "Members area" is internal only. Owners see **Owner account** and
  **Manage my listing**. Reason: other platforms sell members-area
  software for a space's own customers, so the phrase misleads.
- "Written to be quoted by Google and AI assistants" was read as being
  about the description. It is about how the page is built (facts and
  structured data any search engine or assistant can read), so it now
  says **Page built to be found by Google and AI assistants**, on free
  and Verified alike.
- Order within the Verified group on a city or area page: proposed WiFi
  speed, fastest first, rating as tie-break, no reading last. Leonie to
  confirm or suggest otherwise. Position inside the group is never sold.
- Analytics for Verified: lead with actions (website clicks, map opens,
  booking requests); views only with context against nearby spaces;
  nothing public, nothing for free listings. Open whether to offer any
  analytics at all.

## Leonie's scenario questions (21 Sep): rules and build items

**Rules agreed in the answers**

- Every owner change to photos, description, prices or facts is reviewed
  before it goes live, on any tier. Owners see it as pending.
- A free claim that later upgrades is not re-reviewed: the page was
  approved at the claim; the upgrade is only the payment.
- Rejected after paying: full refund in Stripe, subscription cancelled,
  claim kept on record with the reason.
- Cancel or downgrade: Verified runs to the end of the paid year, then
  badge, placement, booking route and advert slot revert. Photos and
  description are kept unless the owner asks for removal.
- Ownership change: the listing is the fixed thing; a new owner makes a
  new claim, which goes to a person because the page is already claimed.
  Old subscription stays with the old card; the new owner starts their
  own.
- A space not on Google Maps cannot be added yet; tell them to set up a
  Google Business Profile first. A manual add form is a later option.
- Temporary closures: Google is the baseline for everyone (nightly
  refresh already marks temporarily and permanently closed).

**Build items added**

1. **Approval hold on paid claims for existing pages.** Today
   `claim_paid()` sets `listing_tier = 'verified'`, the owner details
   and the enquiry email the moment the payment lands, and the next
   push puts them on the page. A wrong or hostile claim on someone
   else's page would therefore go live until undone. Change: a paid
   claim on an existing venue lands as `status = 'paid'` with
   `needs_approval = true`; the control centre shows it as a card
   (name, claimant, email, phone, note, and whether the claimant's email
   domain matches the space's website) with Approve and Refund. Only
   Approve writes the Verified fields and the enquiry address. New
   spaces already wait in the publishing queue, so nothing changes
   there. **Built: migration 71 (`awaiting_approval`, `approve_claim`,
   `reject_claim`) and the Paid, approve? card in the control centre.**
2. **Free claim ownership check.** Confirmation sent to the email on
   the space's own website or Google listing, or a code to its public
   phone, before a free claim completes. Any claim on an already
   claimed page goes to a person.
3. **Owner status toggle: "temporarily closed until [date]".** For
   Verified owners in their account. Goes live without review, since a
   wrong "closed" only hurts the owner. Overrides Google until the date.
4. **Owner-supplied facts survive the Google refresh.** When an owner
   correction is approved, the field is marked owner-supplied and the
   nightly refresh does not overwrite it.
5. **Change log with rollback.** Every approved owner change is logged
   so a page can be put back when a nomad reports it through
   "Something need updating?".
6. **Claim page note for spaces not on Google Maps**, pointing to
   Google Business Profile.
7. **Website and Instagram on the claim form** (optional). Built:
   migration 71 and the About you step.

## Reporting out of the offer (21 Sep, Leonie)

No analytics promised to Verified for now. Raw view counts invite the
wrong comparison with social media numbers. If it comes back it is
indirect (a position such as "third most viewed space in Canggu this
month") plus things the owner already experiences (booking requests in
their inbox). Nothing public, nothing for free listings. Removed from
the comparison page, the memo, the claim screen, the offer email, the
plan page and the Get Listed copy. Verified is now five things: badge,
placement above free listings, booking requests to their inbox, their
own photos and words, their event or offer in the advert slot.

## Order within the Verified group: rotation (21 Sep, Leonie)

Any owner-supplied number (WiFi speed, ratings) can be gamed, so the
order inside the Verified group rotates nightly with the site rebuild.
Built 22 Sep: `rotate_verified()` in webflow_sync.py runs on the
nightly job, gives each Verified page a rank from "999" down,
shuffled with the date as seed, and republishes the live ones in one
call. Free stays "0"; a newly Verified page carries "1" until that
night. The Designer sort is Listing Rank Z to A, then WiFi Rating,
then Google Reviews, so free listings are ordered by WiFi (Jonathan,
22 Sep). WiFi speed stays a fact on the page, owner-reported figures
marked as such.

## Free listings: no request form (21 Sep, Leonie)

A free listing shows "Contact the space" linking straight to their
website, WhatsApp or Google Maps. No form, no auto-reply. The request
form exists only on Verified pages, where it goes to the owner's
inbox. Contact clicks on free pages are counted for the upgrade email
to the space ("43 people tried to contact you from Nomadwise last
month"). Enquiries On already switches between the two buttons.

## Google photos going blank (22 Sep)

Cause: Google photo names, and the plain image links resolved from
them, stop working about four weeks after they are issued. The
nightly job refreshed each venue's snapshot every 30 days, so venues
at the end of their cycle showed a blank photo box (Cafe Gavlen and
Original Coffee by the Lakes, synced 23 Aug; Copenhagen Coffee Lab
Santa Clara, 25 Aug), while venues refreshed more recently were fine.
Fix, three parts: the refresh cycle is 21 days; each refresh also
resolves the fresh photo names to plain links and drops links for
names Google no longer lists (`resolve_photo_links` in
enrich_venues.py); and the app heals itself, so a broken photo on a
card or the detail page fetches fresh names once for that session
and calls `report_stale_photos()` (migration 74), which puts the venue
at the front of tonight's refresh. Cost lever: `RESOLVE_AT_REFRESH`
(6 photos per venue per refresh).

## The free door on the claim page (24 September 2026)

The claim page has two doors, as planned from the start: "Claim for
free" and Verified. A free claim is the same form without payment. It
lands in Paid listings as "FREE CLAIM, APPROVE?" with the same
ownership check as a paid one. Approving records the person as the
owner on the venue (`listing_owner_name`, `listing_owner_email`); the
plan stays free and nothing visible changes on the page. A free claim
for a space not on the map creates it in the normal publishing queue.
Rejecting leaves everything untouched, nothing to refund. The recorded
owner email is what the owner account will log in with, and who the
Verified offer email goes to.

Reference for the owner account: Jonathan's concept demos of 21 Sep
(START-HERE, owner-journey, members-area). We follow them for the
free listing, ownership check by email domain or manual review, the
"My listing" editor with preview, the advert-slot message editor and
the Membership page. We deliberately differ on three points already
decided with Leonie: pay first and approve after (the demo verifies
ownership before checkout); no Performance page and no analytics; no
"nomad perks" as a separate feature (the advert slot carries an event
or offer).

## The Owner account is built (24 September 2026)

nomadmaps.io/owner, see `docs/OWNER_ACCOUNT.md`. Sign in by email
link or Google with the claim's email. My listing (description,
prices, hours, facts, photos, contact) with a live preview; Your
message (Verified only) for the advert slot; Membership. Everything
is a draft until a founder puts it on the page from the new Owner
changes tab in the control centre; Send back carries a note. The
sync writes the content to Webflow within minutes; the message rides
in the unused "Nomadwise Offers" field and the site snippet draws it
in the advert slot (Designer step pending). No analytics, no perks.

## 27 Sep 2026: the Owners tab, and proving ownership

The control-centre tab "Paid listings" is now **Owners**: everyone
who has claimed a page, free or Verified. Sections in order: waiting
for a decision (paid and free claims), payments to match, forms
started and not finished, Verified listings (paid, or made Verified
by us), free listings with an owner on record.

Every claim card checks the claimant against what Google lists for
the place: the phone number and the website. A match on either is
called strong (only the business changes those on its Google
listing). No match is "not proven yet, one WhatsApp message away", with a
button that opens WhatsApp to Google's listed number with the
question already typed (calls do not reliably reach the countries
our spaces are in; WhatsApp does). The phone number a claimant
gives is never used to guess where the space is: the country comes
from Google's address components.

## Food out of the default Google photos (28 Sep 2026)

When a space has no photos chosen for its nomadwise.io page, the app
shows Google's photos, often plates of food. The nightly run now
judges each Google photo once (`photo_suggest.py --food`, after the
snapshot refresh), with the same model and food rule as the website
photo suggestions (FOOD prompts, FOOD_HARD), and lists the food and
drink close-ups in `venues.food_photos` (migration 87). The app leaves
them out of map cards, space pages and share images; a space whose
Google photos are all food still shows them rather than a blank card.
On a space page the founder sees them dimmed and "Show this photo
again" overrules the call for good (`photos_checked` stops the job
judging it twice). No Google calls: it reads the plain links the
refresh already made. First run clears up to 500 spaces; the rest
follow over the next nights.

## Photo links made when someone looks, not for every space (28 Sep 2026)

September's Google bill (£28) was mostly photo links: the nightly
refresh paid for six photo links per space every three weeks, about
6,000 calls per round for ~1,000 spaces, and the whole catalogue was
refreshed on 22-23 Sep so every round lands at once. Google's metrics
by key showed the server key (the GitHub jobs) making ~95% of Places
calls; the app's key about 50 a day.

Now the refresh makes no photo links (enrich_venues.py
RESOLVE_AT_REFRESH = 0). The app makes a photo's link the first time
anyone sees it (PlacesService.linkFor, widgets/google_photo.dart, on
map cards, the space page and the share image), one billed call, and
saves it on the venue for every later visitor (cache_google_photos,
opened to visitors who are not signed in by migration 88, with checks
that the photo belongs to that place and the link is a Google image
link). Only photos people actually look at are paid for. The food
check covers a photo from the night after its first view; the very
first viewer of a photo may still see a food one.

## Counting Google calls by job and bill line (28 Sep 2026)

The Google bill names the kind of call (Place Details Pro, Photos...)
but not which of our jobs made it, and ~7,000 Pro calls in September
could not be traced from the code alone. Every job now counts its own
Places calls under the bill's names (scripts/google_meter.py, one
install line per script, wrapping urllib's urlopen), and so does the
app (services/google_meter.dart, an http client PlacesService uses for
every Google call). Counts land per day, job and bill line in
public.api_usage (migration 89) and show in the control centre,
Analytics, Google calls. Visitors' counts are forced to source 'app'
and capped per report. The inline-script audit workflows (run by hand)
are not counted.

Also: a discovered-place card asked Google for the same reviews twice
at once (signals and quotes); the second now waits for the first.

## Daily Google limit and phone pings (28 Sep 2026)

Google's own quotas cannot cap Places lookups per day (only per
minute), so the limit lives in our code (migration 90). Every counted
call gets Google's list price; public.google_budget() gives today's
estimated spend. At £10 a day (api_limits.places_gbp_per_day) the jobs
(scripts/google_meter.py) and the app (services/google_meter.dart)
stop calling Google until midnight UTC; free calls (photo names, IDs)
still go through. The estimate ignores Google's free allowance, so it
runs high. The phone is pinged once a day each at half the limit, at
the limit, and at 80% and 100% of the map-load cap
(api_limits.map_loads_per_day, 2,300, to match the "Map loads per
day" quota set by hand in Google Cloud). The app counts its own map
loads ("Dynamic Maps") for that.

## After the first full paid test (28 Sep 2026)

The paid path worked end to end (claim, pay with a 100% code, payment
picked up, approve, Verified, cancel, back to free). What it turned up,
fixed in migration 91 and the app:

- Owner account before approval shows the claim and where it stands
  (Claimed, Paid, Ownership check, Verified) with the account laid out
  but locked, instead of "No space on this account yet"
  (owner_pending_claims). Sign-in is pre-filled with the claim email
  (?owner&email=, or the claim made on this device), and Google gets a
  login_hint.
- Owner-facing words say what they did: "You've claimed your cafe /
  coworking space". The thank-you page says "Payment received, you're
  almost there" until we approve; it no longer says "You are Verified".
- Emails: hidden preview line (no more "nomadwiseFOR SPACES"),
  "nomadwise.io" in a sentence is not turned into a homepage link, no
  time promises, no booking button, only what is on the page. The
  page's button is "Send an enquiry" (a form that emails the space).
- Cancelling Verified emails the owner and pings the phone
  (plan_ended, called by the Stripe sync).
- Phone pings: "Someone is claiming X", the real amount and code, and
  "Owners" instead of "Paid listings".
- Owners tab: ownership line without Google's phone (Instagram or the
  website's email, never a phone call), Map and Website buttons from
  the listing, "Enquiries to", the amount paid, newest first.
- claim_paid() is no longer callable from the browser (anyone with a
  claim id could have marked it paid).

## Payments picked up the moment the owner is back (28 Sep 2026)

In the second paid test the owner, back from Stripe, saw "payment not
finished" and the phone heard minutes later: payments were only read
when the Stripe sync next ran (website push every 10 minutes, or
hourly). Now the thank-you page asks for the sync straight away
(payment_returned, migration 92: starts the "Stripe plans" workflow
for that claim, narrowly rate-limited), and the Owner account shows
"Payment confirming" with a live check while it waits, refreshing by
itself every 10 seconds until the claim moves on.

## 28 Sep 2026: "Something need updating?" moves into Nomad Maps

The link on every listing page went to a retired form. It now opens
nomadmaps.io/?update=<slug>. The page separates two people: whoever
runs the space is sent to claim it (free) and change it themselves;
visitors say what has changed (chips plus a note, when they were last
there, optional name and email). Reports go to `listing_updates`
(migration 94, admin-only reads, 5 an hour per space, 60 an hour in
all), ping the phone, and show in the control centre under Owner
changes, Suggested updates, to fix and mark done or dismiss.

## 28 Sep 2026: Leonie's owner-journey review, first round

Decided with Jonathan (28 Sep):

- **Brand.** Nomad Maps now uses Nomadwise red #FF444F (was an orange
  red, #E0442E), the site's page background #F7F7F7, and Roboto, the
  font of nomadwise.io and the logo (was Instrument Sans). App-wide,
  map included: one brand, not a separate business colour.
- **Claim step 3 is "Choose your plan":** a Free vs Verified table with
  ticks, then "Claim for free" and "Go Verified: continue to payment"
  side by side. Claiming is free; Verified is the optional upgrade.
  The side panel on steps 1 and 2 leads with "Claiming your page is
  free". No lock icon; one small line "Secure payment with Stripe".
- **Not only owners.** The claim form asks for a role (Owner, Manager,
  Marketing, Other staff, with an optional job title). Wording is "we
  check you are with the team" instead of "we confirm it is yours",
  in the app and the claim emails (migration 95). How we check: an
  email at the business's own domain matching its website (shown as
  strong in Owners), else one message to the business's own Instagram,
  WhatsApp (the number Google lists) or website email; a document
  only as a last resort, by email.
- **Phone:** country code from a searchable list (defaults to the
  space's country), number digits only, saved as "+351 912345678".
  **Instagram:** the @ is shown in front; a typed @ or a pasted
  profile link becomes the bare handle; anything else is refused.
- **Claim email vs signed-in account:** the email typed in the form
  owns the claim. Signed in as someone else, the form says so.
- **Business sign-in:** the Owner account's sign-in is titled
  "Business sign-in" (for coworking spaces and cafes), with listing
  words only. The nomads' sign-in (reviews, coins) links to it. The
  app also opens the Owner account on /owner and the claim form on
  /claim if a forwarding page is skipped.
- **Owner account:** edits autosave as a draft (3 seconds after
  typing stops, and before Go Verified leaves the page); Save draft
  and Submit for review sit in a bar at the top. The description box
  opens with the page's own description (copied from Webflow's Best
  Text by the website push, migration 96); left unchanged, the page
  keeps its formatting. The preview adds the Instagram handle, the
  map's place and the sidebar advert slot; the Your message tab shows
  where on the page the message sits. "Go Verified" buttons carry no
  price. The Verified list in Membership now names only what Verified
  adds (photos and words are free for every owner).
- **"This place was added by…"** comes off the listing template
  (Webflow Designer, by hand).

## 28 Sep 2026: the Owner account preview follows the live page

Rebuilt from screenshots of Nomio Coworking Lounge's page, in the
order a phone shows it: title ("<name> in <country> - <area>"), the
red place line with country and the Verified pill, wifi / rating /
type, one large photo and four small, the red buttons (Send an
enquiry on Verified, See Accommodation options nearby), grey tags in
the page's own words (Enough Plug Sockets, Skype Room...), the
"Something need updating?" link, the description with its section
headings, prices, the map; then the sidebar: Opening Hours, the round
link buttons (website, map, Instagram), Send an enquiry, and the
advert slot (the owner's green message card on Verified). The map is
drawn, not loaded, to keep Google calls off every redraw. Description
headings travel as "## " lines (copied from the page that way, turned
back into headings by the push); migration 97 re-copies the owned
pages' text so the headings come through.

## 29 Sep 2026: founders can preview any Owner account

To see (and improve) the member area without claiming a space, a
founder opens any listing's Owner account in preview: control centre,
Owners tab, "See any Owner account" (search by name), or "Their Owner
account" on each owner card, or nomadmaps.io/?owner&preview=<slug>.
A dark bar on top switches what the owner would see: claimed free and
not checked yet (the blurred account), paid and not checked, Free
listing, Verified. The editor shows the owner's real draft if there is
one. Nothing saves: Save draft, Submit, autosave and photos are
switched off and say so. Migration 98 (admin_owner_view, admins only).

## 29 Sep 2026: one sign-in door, two kinds of people

The nomads' sign-in led with "Review spaces. Earn coins." and the
coins-to-euros box. It now reads "Sign in to Nomadwise, which one are
you?" with two cards: "I'm looking for places to work" (this sign-in,
selected) and "I run a coworking space or cafe" (opens the Business
sign-in). The coin stats and the 100 coins = 1 EUR box are gone from
this screen; coins are mentioned once, in the first card.

## 29 Sep 2026: no long dashes in owners' words

Long dashes read as machine-written. When an owner's description or
Verified message goes on the page, the push turns any long dash (and a
spaced hyphen) into a comma: "tables—and" becomes "tables, and".
Hyphens inside words stay. Our own copy follows the same rule.

## 29 Sep 2026: prices in the right currency, and a kinder "sent back" email

Kopi Club (Kandy) submitted a cappuccino price of "2", no currency. The
Owner account now sets the currency from the space's country (Sri
Lanka: LKR, Indonesia: IDR, Portugal: EUR; from the Unicode CLDR list),
shows it beside every price box, and takes the amount only. The page
gets euro, pound and dollar with the symbol in front ("€3.60") and
every other currency with its code after ("900 LKR", "40k IDR").
"Change currency" covers spaces that price in USD. Existing prices keep
the currency written in them.

Sending changes back always emailed the owner; migration 99 rewords
it from a rejection to "a small suggestion", with the note and a
button to the Owner account, and logs a failed send in Emails to
owners.

## 29 Sep 2026: the back and forth with each owner, in one place

Each space now has a History (control centre: "History" on an owner
change card or an owner card, or from any email in Emails to owners):
claims, approval, every submission of changes (with what was
submitted), notes sent back, changes put on, visitors' suggested
updates and every email, each opening to its full text. Emails keep
their text from migration 101 on. Owners' replies arrive in the
hello@nomadwise.io inbox, not here. The space page's photos also get
left and right arrows on a computer, where a mouse cannot swipe.

## 29 Sep 2026: Owners, a user group of their own

Users -> Group now has Owner beside Customer, Friend and Team. It is
set by hand like the others, and automatically (migration 102) when an
email submits a claim, free or paid, or is the listed owner of a
space, including an owner who first signs in later. Automatic marking
only fills an empty group: it never changes Team or Friend, and moving
someone back to Customer by hand sticks unless they claim another
space.

Coins are for remote workers only. Signed in as an Owner, the app
hides the wallet, coin chips, coin wording, "How coins work", "How it
works" (two of its three pages are about coins), the Leaderboard and
"Own a space?", and the menu leads with "My Owner account". Owners are
left off the public leaderboard and out of the Customers view in
Analytics. No Cafe / Coworking / Coliving subgroups: the wording
follows the space's own type, and coliving will come as a space type.

## 29 Sep 2026: checking a resubmission in seconds

When an owner submits again after we sent their changes back, the
Owner changes card opens with "Submitted again after your note": the
note we sent, then only what they changed since, with the description
marked word by word (green is new, red was taken out) and every other
field as before → after. If they changed nothing, it says so. The
full comparison with the live page is still there, folded under
"Everything compared with the page today". It reads the sent-back
draft itself, which is never edited afterwards, so it also works for
notes sent before today (Kopi Club).

## 29 Sep 2026: WhatsApp from the control centre

Owner cards (Owners tab) and Owner changes cards now have green
WhatsApp buttons: "WhatsApp <first name>" for the person who claimed
the space (the phone from their claim form) and, when it is a
different number, "WhatsApp the space" for the number on their page.
Each opens a chat with a short hello already typed. A number typed
without its country code gets the space's country code. No button
shows when there is no number.

## 29 Sep 2026: quick questions in the Owner account

To learn what owners value and would pay for, without calls: the
Owner account shows one small card, "Help shape your Owner account",
with one question answered by tapping (or "Something else" in their
own words). At most one new question every 3 days unless the owner
asks for another; "Not now" puts a question away for 30 days. Answers
show in the control centre under Owners, "What owners tell us",
counted per answer with every own-words answer and who said what.

The first nine questions (migration 104, editable in the
owner_questions table): how people find them, what would help most,
which extras are useful, monthly or yearly, a monthly and yearly
price side by side (9 a month or 90 a year, the same money, to test
the format and not the amount), a featured spot at a randomly picked
monthly price per space (5, 9, 15, 25 or 39, the same for that space
every time) to see how the answer moves with price, marketing spend,
what a member spends with them, and who decides. Prices show in euro
for euro countries, pounds in the UK, dollars elsewhere.

## 29 Sep 2026: Free first on the claim page

Owners arrive from "List for free" on nomadwise.io, and the claim page
opened with a €99 box beside the search, which read like a bait and
switch. Steps 1 (find or add your space) now show "Two ways to be on
Nomadwise" below the search: Free first (red border, "Where every
space starts", €0 always, what it gives) and Verified beside it
("Optional", €99 a year, everything in Free plus its extras), stacked
Free first on a phone. The ordering benefit now says it plainly:
Verified spaces are always shown above free ones in their city and
area, "which counts for more as more spaces join", since a first space
in a new area (Westerwelle, Arusha) has nobody to be above yet.

## 29 Sep 2026: the description goes into More Info, the cappuccino into its own field

Jonathan's correction: More Info is the description visitors see on a
listing; Best Text is used for something else on the site. The owner's
description now goes into both. The cappuccino price goes only into
its own field (Cappuccino Price, already filled on about 410 pages),
never as a line in More Info; day, week and month passes follow the
description in More Info, one line each. When the description is
unchanged, More Info keeps the page's own text (older pages keep notes
there) minus any price lines written before. The Owner account's
description box now starts from More Info (Best Text if More Info is
empty). Kopi Club fixed by hand the same day. On the page, the
cappuccino price is best shown in the top row beside WiFi speed and
rating (Designer: copy the WiFi item, bind it to Cappuccino Price,
show it only when set).

## 29 Sep 2026: page titles never repeat the place

New pages no longer say the place twice when the space's name already
ends with it: "Westerwelle Startup Haus Arusha" in Arusha gets the
heading "Westerwelle Startup Haus in Arusha" and the title "Westerwelle
Startup Haus: Coworking Space with WiFi in Arusha". Only a trailing
place is dropped (with any comma, dash or brackets before it), never
the whole name; a name with the place elsewhere ("Arusha Coworking
Hub") keeps its name and drops the "in Arusha". The page name itself
(and its address) stays the business's full name. Westerwelle fixed
by hand the same day.

## 29 Sep 2026: Leonie's Stage 3 review of the Owner account

- S3-1 slow first load: the start screen now has a moving bar and
  "Loading places to work…", then "Almost there. The first visit takes
  a little longer…" after 6 seconds; the browser opens its connections
  (app engine, maps, fonts, database) while the page arrives. The app
  itself is downloaded once and then kept by the browser.
- S3-2/3 "We email you at": a founder's preview showed the founder's
  address; it now shows the owner's (migration 105). Real owners
  always saw their own.
- S3-5 description: no more "##". An opening text box, then sections
  the owner adds, each with a heading box and a text box. Stored the
  same way as before, so the page and the sync are unchanged.
- S3-6 currency: a dropdown you can type into, the space's own
  currency first, one for every price.
- S3-7 numbers: owners type either way; leaving the box tidies it to
  one format (1,000 and 3.60; "1.000" means a thousand, "3,6" means
  3.60, "40k" stays).
- S3-8 hours: picked, never typed: Not set, Open (from and to, every
  half hour), Closed or Open 24 hours per day, and "Use Monday's hours
  for every day". Split hours already on a page are kept as they are.
- S3-9 Instagram: the handle only, with the @ shown in the box; links
  and "@" are accepted and tidied.
- S3-10 WhatsApp: optional, with the country code picker; "leave empty
  if you do not use WhatsApp" (Jonathan: no general phone field, as the
  page has only a WhatsApp button and Webflow's field limit is full).
- S3-12 the message card uses the logo's blues (#E8F8F9, #004854)
  instead of green, in the app and in the site snippet (footer code to
  update in Webflow).
- S3-13/14 buttons on the claim page and in the Owner account: 4 px
  corners and Roboto semi-bold, as on nomadwise.io.
- S3-15 "Change membership" button, an email to hello@nomadwise.io
  with the space's name, so we can help and ask why.

## 29 Sep 2026: owners help decide what we build next

The Owner account has a fourth tab, "Build next": "Help us decide what
we build next", framed as asking for their help to make the things
that help spaces like theirs do well. Ten ideas as tap-to-vote cards
(as many as they like, tap again to take a vote back): day pass
booking, an enquiries inbox, events, offers for remote workers, a
WiFi-tested poster and badge, reviews from remote workers, memberships
sold through the page, team access, ready-made social posts, and a
featured spot in their city. Below, "Have an idea of your own?" takes
their words. Founders see the ideas ranked by votes, who voted, and
every own idea at the top of What owners tell us (migration 106).
Ideas live in the owner_ideas table, so they change without an app
update. No promise of dates: "we will let you know when one you voted
for is ready".

## 29 Sep 2026: Plan & billing, self-serve

Emailing us to change or cancel is not a good service (Jonathan). The
Owner account's Membership tab becomes "Plan & billing": the plan and
its status, the next payment, the card on file, every invoice to view
or download, Free and Verified side by side with "Switch to free"
(renewal off, Verified to the end of the paid year, optional reason)
and "Keep Verified" to undo, and Stripe's secure page for the card and
billing details, opened at the right step. Read live from Stripe from
Postgres (http extension, a restricted key in the Vault as
stripe_billing_key; docs/BILLING.md), so no webhooks or extra servers.
Switches are logged and email the team with the reason. Until the key
is in the Vault the tab shows our own records and a way to reach us.
Also: the admin menu now starts with the team's tools, in this order:
Control centre (renamed from "nomadwise.io"), Analytics, Users,
Review submissions, Feedback inbox, Sweep a city.

## 29 Sep 2026: the photo layout follows the photo count

A page's Images entry has a "Has Enough Images" switch: on shows the
big grid (one large photo, four small), off the simple slider. Older
entries had it set by hand, so Jiboia Studio (five photos) showed the
slider; fixed by hand the same day. Now every night the sync sets it
on for four or more photos and off for fewer, on every page, and
republishes those that are live. When an owner's photos are put on the
page they now also replace the page's photos (the Images entry had
not been updated before), with the switch to match. The nightly
opening-hours fill now covers every page we know, not only those the
control centre created (Jiboia's hours were empty).

## 29 Sep 2026: emails only link to a live page

The "quick note about your changes" email linked to "Your page as it
is today" even when the space had no live page yet (seen in Leonie's
test with Coastal Cowork Collective Ericeira), so the link opened
nothing. A page address can be saved before the page is live, so the
owner emails now link to a page only when it is live (the same test as
the "is live on Nomadwise" email, migration 108). Emails that had a
link line now leave it out, or say the link follows once it is live.
The "your changes are on the page" email says, for a space with no
live page yet, that the changes are approved and will be on the page
when it goes live.
Parked (Jonathan, "leave it for now"): an AI-suggested, kind note
written from what the owner entered when changes are sent back,
because a note like "these changes aren't good" is not how we want to
talk to a space. Needs a choice of AI service and a key in the Vault.

## 29 Sep 2026: Owner account on a phone

At the top of the Owner account the "See my page" link was cut off to
the right of the Verified label on a phone; it now sits on its own line
under the space's name there, and long names wrap. It also shows only
when the page is live, like the emails. Under the description, the
character count ("36 / 3,000") squeezed the "Add a section with a
heading" button; the count now sits on its own line under the text
("36 of 3,000 characters") with the button below. Price boxes no
longer take two dots or commas in a row ("1,,2", "33....3").

## 29 Sep 2026: a tighter, sharper Owner account

Jonathan found the Owner account "a bit big" and not as sharp as
Slack, Uber or Tripadvisor. The owner screens (Owner account and the
claim page) now use: 42 px buttons with 14.5 px text; boxes with
15 px text, tighter padding and 6 px corners (they had 14 px corners
next to 4 px buttons); cards with 8 px corners and 16 px padding on a
phone; headings a step lighter. On a phone the four sections are one
row of tabs with a line under the chosen one (was two rows of big
pills), prices sit two boxes to a row, and the founders' preview bar is
one slim line that swipes sideways. The page preview keeps the
website's own look.

## 30 Sep 2026: the team's own link

nomadmaps.io/admin opens the control centre straight away, without
the map and its menu (Jonathan). Signed out, it shows one "Continue
with Google" button that comes back to the same place; a non-team
account gets a polite note and the way to the map (the database still
checks every call, the link grants nothing). nomadmaps.io/?admin=analytics
and ?admin=users open those screens directly. Opened this way, the
control centre's title bar has a tools menu (Analytics, Users, Review
submissions, Feedback inbox, Open the map). The control centre's title
now reads "Control centre" (was "nomadwise.io"), like the menu.

## 30 Sep 2026: control centre and analytics upgrade

Everything from the admin wish list, built together:

- Analytics counts in the database (migration 109, admin_analytics):
  the page used to download at most 2,000 recorded actions and count
  them on the phone, which quietly undercounted once traffic grew. Same
  rules for who counts (team devices, bots and data-centre visitors that
  never act like a person are left out; Friends and Customers views).
- A 7, 30 or 90 day choice, each headline number with its change on the
  period before (green up, red down, "new").
- Where visitors come from: utm_source or ref on the link, else the site
  that sent them (recorded from today as 'referrer' on app_opened),
  grouped into Google, Instagram, nomadwise.io, WhatsApp and so on.
- The owners' funnel: claim page opened, form started, claimed free,
  went to payment, paid for Verified, with the period before.
- Searched for, little found: every Google place search now records how
  many of our spaces are within 5 km ('place_searched'); places searched
  with two or fewer show where to sweep next.
- The visitor list shows the latest 100 and loads a visitor's actions
  when opened (admin_visitor_trail).
- Control centre: a To do line on top (claims to decide, payments to
  match, owner changes, pages to approve, blocked, new spaces, pages in
  Webflow, sitemap entries, closed places), each item a tap to go there.
- Three sections, Owners, Pages and Clean-up, each with its waiting
  count, instead of eleven tabs in one row; a chosen tab now stays chosen
  when it empties, with its empty note.
- Search across everything (magnifier in the title bar): spaces by name,
  city, page address or owner email, and claims by space, owner name or
  email, each with Show in list, Open the space, Open page, Their Owner
  account, Listing plan and History.
- Send back has ready-made friendly notes to tap in and adjust (about the
  space, prices, photos, too salesy, hours, contact details, English).
- A Money card at the top of Owners: Verified, paying through Stripe,
  renewals in the next 30 days, and who switched to Free in the last 90
  days with their reason.
- A health check (heart in the title bar, green, amber or red dot): the
  last run of the nightly jobs, the website push, Stripe plans and the
  app build, read from GitHub, and today's Google spend against the
  limit.
- The title bar just says "Control centre"; the To do line replaced the
  "N to do" badge so the buttons fit on a phone.

## 30 Sep 2026: Owners on the Analytics page

The audience switch on Analytics is now Everyone, Friends, Customers and
Owners (Jonathan). Owners shows only the devices used by owner accounts
(people who run a space), so we can see how owners use the app and
their Owner account; Customers still leaves them out. Migration 110
adds p_segment 'owners' to admin_analytics; the coin economy has no
Owners view, as owners earn no coins.

## 30 Sep 2026: Google costs explained, with a limit and pauses

"What caused £1.26 today?" (Jonathan). The Google calls page now
explains each day job by job: what the job costs, its share, the calls
behind it in plain words ("99 × name, type, open or closed, photo list",
Place Details Pro) with each line's price, and what the job is for.
Earlier days open the same explanation with a tap; the month shows the
cost per job. From the same page (migration 111):
- the daily limit can be changed (£1 to £500; was a database edit);
- any job can be paused (nightly refresh, website sync, website push,
  photo suggestions, photo check, visitors in the app). A paused job
  asks Google nothing and the others carry on; the jobs read the pauses
  from google_budget() before every call (scripts/google_meter.py), the
  app likewise (GoogleMeter), where the map still works and saved
  details show instead.
The health check links to it ("What it was spent on, and pause or limit
it"). Its amber warnings for the website push and Stripe jobs now wait
3 and 8 hours: GitHub starts frequent scheduled jobs late as a matter of
course, which is not a fault.

## 1 Oct 2026: Google's free calls on the Google calls page

The Google calls page now takes Google's free monthly calls into account
(Jonathan: "where will it result in an actual £0 cost"). A card shows,
for each line of the bill, how much of this month's free allowance is
used (10,000 for Essentials lines and map loads, 5,000 for Pro, 1,000
for Enterprise and photos) and anything billed beyond it. Every day,
job and line shows its list price next to its real cost, with the free
calls used up in date order within the month, the way Google applies
them; "Free" in green where it costs nothing. The daily limit still
counts at list price, as a safety net. The allowance belongs to the
whole Google billing account (shared with anything else on it), and
Google's own billing page has the final word; we cannot read the
account itself from here.

## 1 Oct 2026: Remove an owner; the Coastal test owner removed

Leonie tested the owner journey on Coastal with a throwaway account,
and the page went through to Webflow as a draft. Jonathan wants the
draft kept (the real owner may claim it later) but not the test owner.
Migration 112 adds remove_owner(): the plan goes back to Free with no
owner, enquiry address, dates or Stripe link; the sync writes the Free
fields to the Webflow item (a draft stays a draft, nothing is
published); the owner's claims for the space are closed as abandoned
(no email); their waiting changes are dropped; the space's Stripe
orders are marked ignored so the hourly Stripe check never re-attaches
them; their account leaves the Owners group if they run no other space;
and a dated line goes into the notes. Stripe itself is not touched: a
live subscription is cancelled in Stripe by hand. The migration runs it
once for the Coastal test account and clears that account's answers,
idea votes, suggestions and billing events, so the Owners figures show
real owners only. The Listing plan page gains a "Remove owner" button
(founders only) for the next time: a test, a space that changed hands,
or a claim by the wrong person.

## 1 Oct 2026: Every enquiry reaches the space (Enquiries to pass on)

A nomad (Jan, 30 Sep) used Send an enquiry on Madeira Friends Hub, a
page we listed without the space knowing. The pop-up on free pages is a
Webflow form ("Research Form") that only emailed hello@nomadwise.io, so
the space never heard about it. Decided with Jonathan:

- The pop-up stays exactly as it is, so nomads never leave nomadwise.io
  (Jonathan's worry about continuity). The ten-minute website push now
  reads its submissions over the Webflow API (scripts/
  webflow_enquiries.py) and files them in the enquiries table next to
  the Verified form's requests. Webflow still emails hello@ as before,
  as a backup. Submissions from before this went live are kept as
  history (they count towards a space's enquiries) with nothing to do.
- Verified with an enquiry address: sent straight to the space, as
  before.
- Not claimed, or claimed on Free: the enquiry waits under Owners >
  Enquiries in the control centre, first in the To do strip, and the
  phone is pinged. The job looks for an email on the space's own
  website and suggests it. Pass on emails the space (reply-to the
  nomad, copy to hello@) with a free claim link, or for a Free owner a
  line about Verified; optionally tells the nomad it went. Already
  handled, Can't reach (optionally sends the nomad the space's website
  and Google Maps link) and Spam close it. A submission whose listing
  name is not recognised gets "Choose the space".
- Free stays "enquiries come to us first and we pass them on";
  Verified keeps "straight to your inbox".

Migration 113. The control centre shows when the pop-up was last read
and any problem, such as the Webflow token missing the "Forms: read"
permission. Since the import routes Verified pages directly, Verified
pages could use the same pop-up instead of the nomadmaps.io form.

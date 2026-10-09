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

## 1 Oct 2026: Suggested replies for Send back

Send back (owner changes) now suggests replies worked out from what the
owner entered (Jonathan: "give options when we select send back, click,
it fills a draft reply, we check the words, then send"). The checks
(widgets/reply_suggestions.dart) look for: no or a very short
description (under 25 words) or a very long one (over 350); salesy
wording ("the best", "number one", capitals, exclamation marks); a phone
number, email or link inside the description; a description not in
English; prices typed with symbols or text instead of plain numbers, and
a shorter pass costing more than a longer one; fewer than three photos;
a WhatsApp number without a country code; an Instagram entry that is not
a handle; a website box with no address or a social link; an enquiry
email that is not an email; and on Verified pages, a long or salesy
message headline. Each suggestion is a friendly, specific note; tapping
it adds it to the reply box, "Use all" puts them together, and the
general replies remain below for anything the checks cannot see. Rules,
not an AI model: free, instant, and the same words every time. Nothing
is sent until the founder presses Send back. Migration 114 lifts the
note limit from 1,000 to 2,500 characters (longer notes used to be cut
off without a word).

## 1 Oct 2026: Verified priced by region, monthly or yearly, in four currencies

Leonie's green light on the pricing framework (Notion, "Owner features
and pricing ideas"), with one change: Indonesia sits in C (Middle),
not D. Four country groups, monthly or yearly (yearly is ten months
minus one, so it ends in a 9): A 15/149, B 10/99 (the anchor, today's
price), C 6/59, D 4/39 EUR, with clean native amounts in GBP, USD and
AUD rather than a live exchange rate (see docs/BILLING.md for the
table). Currency: the UK pays in pounds only; Europe defaults to
euros, Australia to Australian dollars, everywhere else to US dollars,
each with a toggle to the others (Jonathan). One price for all space
types; monthly in every group; the price follows the space's address.
No founding-price offer: normal prices first, see how sales go
(Jonathan). The "2 months free" badge on yearly and, once a space's
day pass is known, "less than one day pass a month" are the two
persuasion lines on the page.

Built (migration 115): pricing_groups, 243 countries with their group
and default currency (editable on the new Pricing page in the control
centre, with unknown country names listed to map), pricing_for() for
the claim form and Owner account, and start_checkout(): one Stripe
Checkout session per claim in the chosen period and currency, through
the database's Stripe key, so no backend was needed. The claim form
gets a monthly/yearly switch and a currency toggle; the plan table,
the Owner account's billing tab, the control centre's offer email and
the two owner emails that quoted "99 EUR a year" now say the price for
the space's country. The hourly Stripe sync caches every price's
amounts so the page shows exactly what Stripe charges. Until the
Stripe price ids are entered, every path behaves exactly as before
(99 EUR a year through the payment link). Anon statements get 15 s
(Supabase's 3 s default would cut a slow Stripe round trip short).
The control centre's "Copy payment link" became "Copy claim link":
the claim page shows the right price and carries the owner's email.

## 2 Oct 2026: Claim form, step 2 and 3 polish

- "Where should enquiries go? (optional)" became a ticked box, "Send
  enquiries from nomads to <their email>", with the field appearing
  only when unticked (Jonathan's idea: the normal case needs no
  typing, and "optional" never had to be worked out). Unticked and
  empty is refused with a plain message.
- The Verified column of the plan table was tinted red, which reads as
  a warning; it is now the brand teal tint with the green Verified
  icon beside the name. Column sub-labels say "€0" and the chosen (or
  "from") price. The small print under the buttons is one sentence
  each: "No card needed. Nothing to pay, ever." and "Paid monthly /
  once a year through Stripe. Cancel any time."
- Prices are written with their symbol everywhere (€10, £9, A$25),
  never "10 EUR" (migration 116 for the email words).

## 3 Oct 2026: every space gets its country

The Pricing page counted 32 spaces across the four groups: most spaces
had no country recorded, so Verified would have been priced as group
B for nearly everyone. Migration 117 copies the country from the
site's Region for every space whose city is a Region, and the nightly
Google job (enrich_venues.py) fills the rest from Google's address
parts, a few hundred a night, within the free tier. A country already
on a space is never overwritten; founders can still change a space's
group on the Pricing page by country.

## 3 Oct 2026: prices live; "from €4" before a space is picked

All eight prices are in Stripe and the Pricing page shows every group
"In Stripe" (678 spaces mapped). The claim form's first step, before
a space is chosen, showed group B's "€10 a month, or €99 a year" as
if it were the one price. pricing_for() now also returns the cheapest
Verified price across the groups (migration 118), and the form says
"from €4 a month, the price depends on the country of your space"
until a space, and so a country, is known; then it shows that
country's own price in its own currency. Stripe's product description
was rewritten to the five things Verified gives (enquiries, not
"booking requests"; no analytics report).

Same day, the two plan cards under the search box (Jonathan): they
needed a scroll to see whole on a laptop, so they are shorter now
(smaller price, tighter spacing, the small print as one line under
both cards instead of a paragraph in each) and sit closer to the
search. Each card is also a choice: tapping Free or Verified selects
it, with a tick in the corner, and step three leads with the filled
button for that plan (the other stays outlined, so nothing is final).
Free is selected to start with. Tracked as claim_plan_pick.

Later the same day, step three became a pricing page (Jonathan, with
Canva and Zoom as the examples): a Monthly / Yearly switch with the
"2 months free" pill at the top and "Prices in" beside it, then Free
and Verified side by side, each with its price, its own button and
what it gives, all on one laptop screen. The tick table and the
separate "pick how to pay" box are gone. Verified wears a
"Recommended" pill; Free keeps "Where every space starts". The old
Monthly / Yearly segments were uneven (the yearly one had a second
line), which the switch avoids.

## 3 Oct 2026: a country for every space, from what the site knows

TMO Coffee Bali Kedungu Beach was priced at €10 (group B) on the
claim form: it had no country, because migration 117 only matched a
space's city to a Region, and Kedungu is a Location inside the Bali
Region. "Bali" itself was already an alias for Indonesia; the gap was
spaces with no country text at all. Migration 119 adds
venue_country_guess(), which reads the country from the page proposal
the sync prepared, the Location or Region a founder picked, the city
or neighbourhood being a Location or Region on the site, Google's
cached address parts, or the nearest Region within 30 km (the sync's
own rule; the sync now copies the Regions' coordinates for it). It
ran once for every space without a country, runs from a trigger when
a space without one is added or touched, and the sync calls
fill_venue_countries() after copying the Regions. The Pricing page
says how many spaces still have none. A country already on a space is
never changed.

## 3 Oct 2026: no "from €4" anywhere a European owner can see it

"From €4 a month" is the cheapest country's price. An owner in
Lisbon reads it, then sees €10 on the next screen and feels cheated
(Jonathan: like a UK Spotify subscriber seeing the Vietnam price). So
no figure is shown until the country is known. The Get listed page
says "Verified costs around a day pass a month" (the anchor the
prices were set by, true everywhere), and the claim form's overview
card says "Around a day pass a month, priced for your country" until
a space is picked, when it shows that country's own price. The
cheapest-price fields from migration 118 stay in the database but
nothing shows them.

Same day, the overview cards on step one lost their big price line
altogether ("Around a day pass" in a 30px numeral looked odd, as
Jonathan said a funded SaaS would never ship it). Both cards now carry
one bold sentence where the price was, at the same weight: "Free,
always" and "About the price of a day pass a month", each with a
grey line under it, and nothing says "priced for your country". The
real numbers appear on step three, once the space is known.

The Verified card's pill says "Added value" (Jonathan's wording),
not "Recommended": a recommendation from the seller is discounted on
sight (Jonathan). "Gets enquiries" was tried and dropped the same
hour, since free pages get enquiries too (passed on by us), so the
Free card now says so and the Verified line says "straight to your
inbox from the button on your page". "Above free listings" and
"Shown first in your city" were tried for the pill and set aside. The line under the two cards is a size larger and
darker, so it reads as part of the page.

One corner radius on the claim form (Jonathan): the plan cards had
16 px corners next to a 6 px search field and 4 px buttons, which
looked like two products. siteButtons() takes a radius now; the claim
form passes 16 for fields, buttons, result tiles and cards alike, and
the Owner account keeps its 4 px.

## 3 Oct 2026: back from Stripe lands on step three, not an empty form

Jonathan: "Go Verified" opens Stripe; Back or Cancel returned to an
empty step one, and step two had forgotten everything. The form now
saves a draft on this device when step three opens and again on the
way to Stripe (space, details, plan, period and currency), and on the
next visit within two hours puts the visitor straight on step three
with it all in place and a line saying nothing was charged. The
thank-you page clears the draft, so a finished claim never resumes.
A link for a different space (?claim=<other>) wins over the draft.
Step three also shows the space's name large in its own card instead
of inside a sentence, and the small print under the buttons is a size
up. The claim emails open "You've claimed your ...", not "Thanks,
you've claimed ..." (migration 120).

The one incentive to choose Verified now rather than later is
priority (Jonathan, 3 Oct; a price lock was ruled out because the
price is not going to change): step three says under the Verified
price "Verified claims are checked first, so the badge and the
enquiry button go on sooner", and under Free "A person checks your
claim in the order claims arrive", so Free still reads as a good
choice. No time is promised. The control centre's waiting list puts
paid claims first so the words are true.

## 3 Oct 2026: Outreach, a list of the spaces we talk to

For a year spaces have written to hello@ asking to be listed or to
change a page, and were told "when the members area is ready"; many
form submissions were never answered. Jonathan asked for a CRM inside
the control centre. First slice (migration 121, docs/OUTREACH.md):
space_contacts with a stage each, the messages in both directions,
reply templates filled in per contact, sending through Postmark with
guard rails (30 days between emails, 40 a day, unsubscribe on every
one), and Claimed / Verified moving by themselves from the claim form.
Website form submissions are filed by the sync. The inbox backlog (97
threads, 78 spaces, read from Gmail on 3 Oct) is imported from a file
through the app, not a migration: the site is built from the
repository via GitHub Pages, so personal details stay out of it.
Chosen with Jonathan: inbound backlog first, send from the control
centre, stages automatic where possible. Next slices: the invitation
to spaces already listed, and adding prospects from the map.

Jonathan asked to link Outreach to Spark, where the three inboxes
(hello@, jonathan@, leonie@) are read. Spark is a mail app with no way
for another program to send through it (its integrations only export
an email to a task app), so the link is "Open in mail app": the
filled-in email opens as a draft there, a founder sends it from their
own inbox, and "I sent it" records it (migration 122). That is also
the right route for invitations to spaces that never wrote to us,
which do not belong on Postmark. A fuller link (sending and reading
through the mailboxes themselves) waits on knowing who hosts them.
The outreach framework as a whole is a proposal until Leonie has
chosen between the options put to her; nothing has been sent.

Migration 121 failed on its first run: the unsubscribe token used
pgcrypto's gen_random_bytes(), which on Supabase lives in the
"extensions" schema and is not found from public. The runner applies
each file in one transaction and records it only on success, so
nothing was half-applied and the same file is retried on the next
build; it now uses the built-in gen_random_uuid(). The local test
database had pgcrypto in public, which is why the test passed; the
test database is now laid out like Supabase (pgcrypto in
"extensions"). The backlog is 78 contacts, not 79 as first reported.

## 3 Oct 2026: Outreach templates, listed spaces, spreadsheet rows

Three asks from Jonathan on first opening Outreach.
Templates can now be made, renamed and deleted as well as reworded
(migration 123); a placeholder we do not fill in is refused on saving,
so a typo is caught there and not when an email is about to go.
The spaces already on nomadwise.io come in with one button
(migration 124): they were in our database all along, so nothing is
typed or pasted. Addresses we lack are read from each space's own
website by the sync. Bringing them in sends nothing; inviting them
waits on Leonie.
The clipboard import also takes rows copied from a spreadsheet.
Reading a pasted picture was asked for and not built: the app has no
way to read an image by itself, and doing so would mean connecting a
paid reading service. For now a screenshot is turned into an import
file in a Claude session.
Also fixed: the chosen stage chip showed dark words on a dark chip,
and refusal messages from the database were cut at the first comma.

## 4 Oct 2026: "How it works" in Outreach

Jonathan asked for instructions inside Outreach. A "How it works"
button at the top opens one card with eight short sections: what it
is, the groups, the stages, getting spaces in, writing to a space,
what to do when they answer, templates, and the rules built in. The
paragraph that used to sit at the top is now one line.


## 4 Oct 2026: Page upgrades in the control centre

Jonathan asked for a place in the control centre where improvements
to coworking pages are lined up by likely impact, with buttons to ask
for more, and where nothing changes until he presses Go.
Built as Page upgrades (migrations 125 and 126,
docs/PAGE_UPGRADES.md). Each card is one change to one page with
before and after; Go sends it through the website push, Undo puts the
old text back.
Two kinds can be written to pages now. Search descriptions are built
in the database from the facts we hold (1,008 of 1,011 pages shared
one generic line), so more can be prepared at any time. Page
descriptions have to be written from each space's own website, so
"Ask for a batch" files a request and the batch is drafted in a
Claude session and uploaded; the app cannot write them by itself
without a paid writing service, which was not wanted for now. Prices
and WiFi are shown as gaps.
The queue is ordered by page views of each listing page (90 days,
from PostHog), Google reviews and type. Pages with an owner keep
their owner's description.
The nightly sync now records what each page holds
(venue_page_facts), and the sync report carries the open requests.
An independent review before shipping found that a retry after a
half-finished write could have stored the new text as the "old" one
and broken Undo, and that Take back could race the push. The push
now claims each change in the database just before writing
(upgrade_begin), which also keeps the text being replaced.

## 4 Oct 2026: Photos in Page upgrades

Counted from the Images collection: 597 of the 1,011 live pages have
fewer than five photos and 378 have one; 541 of the 597 are cafes.
Jonathan wants every page at five. Offered to have the app propose
Google photos for existing pages as it does for new ones; he chose the
manual way he already uses for new listings: open the place on Google,
copy a photo's image address, paste it into a slot.
So Page upgrades has a Photos row (migrations 127 and 128). It lists
the pages short of five, most visited first, and opens the existing
photo page with the page's current photos in the slots. Saving sends
the list to the page through the same approve, write and undo path as
the text upgrades. The nightly sync records each page's photo count
and links.
Safeguards added after review: a save is refused when the page's
photos changed after the photo page was opened; a page whose owner has
added photos in the Owner account is left out and never written over;
the push stops if the page holds a photo the founder never saw. Not
compiled or run against the live website before upload: see
`docs/PAGE_UPGRADES.md`.

## 4 Oct 2026: Search box in Clean-up

Jonathan asked for a search box on the Closed list (69 places) that
narrows the list while typing. Added to both Clean-up lists, Closed and
Not for the site. It matches every typed word against the name, area,
city, country, page address and, for hidden spaces, the reason. The
lists are already loaded, so it filters on the screen with no request;
the Temporarily and Permanently closed chips count what is left.
Same upload: the Retire dialog no longer promises a redirect. The sync
asks Webflow to add one (`POST /v2/sites/{site}/redirects`), which
Webflow documents under its Enterprise API, so on other plans it is
refused and the card shows the two addresses to add by hand. The
dialog and the retired card now say so.

## 4 Oct 2026: Two ticks on a retired card

Jonathan asked for a tick for each of his own steps after a page is
retired (the redirect, the sitemap), and for the card to go once it is
marked complete. A retired card now shows two ticks and a "Mark as
complete" button that is live only when both are ticked. The ticks are
kept in `venues.website_retire_note` as `redirect_done` and
`sitemap_done`, so they survive a reload; "Mark as complete" sets
`website_retire_done_at` as before, which takes the card off the list.
When Webflow did not take the redirect from the sync, the card gives
the old and new path with copy buttons.

## 4 Oct 2026: Candidates, the list between the map and the site

Jonathan wanted the places the nightly job finds to queue up in the
control centre for him to review and decide whether each gets a page.
The pieces existed (Sweep a city, the nightly review scan, the
"promising" pins, the pipeline from New spaces to Webflow) with one
link missing: a promising place only reached New spaces after someone
reviewed it in the app. Nothing listed the promising ones to decide on.

Candidates is that list (migration 129, `candidates_tab.dart`), the
first chip under Pages. A candidate is a discovered place that is not
a space yet, was not turned down, and either passes the map's
"promising" rule (reviews mention wifi, plugs or laptops, none warn
against working there) or is a coworking space. Best first: laptop
mentions weigh most, then plugs and wifi, coworking gets a head start,
rating and review count break ties. Worked through city by city: the
chips are the site's city pages (nearest Region within 30 km) with
candidates near them, busiest first.

Two decisions per card:
- Queue for the site: the place becomes a space, already queued
  (`candidate_queue`), and carries on through Queued, Ready to approve
  and In Webflow like any other. Nothing reaches Webflow without the
  Approve that was always needed. Google is asked once, at that tap,
  for the city and country, so the space is filed under the right city
  page from the start.
- Not for the site: off the list with a reason from the control
  centre's own list, kept in `candidate_decisions` (founders only),
  with a way back under "turned down".

Decided:
- A candidate skips New spaces and goes straight to Queued. New spaces
  is for spaces nomads verified; a founder who taps Queue on a
  candidate has made the same decision the Queue button there records.
- Candidates are not counted in To do or in the Pages number. They are
  a backlog to work through, and a standing count of hundreds would
  bury the items that are waiting on a person.
- Review quotes are shown only when asked for ("What reviews say"),
  one place at a time: each look is a paid Google call.
- The decisions live in their own table, not on `discovered_places`,
  because anyone may write to that cache.
- Not built yet, on purpose: leads scraped from other directories, and
  reading more than Google's five reviews per place. Both would feed
  this same list, so the list came first.

Also new: `.github/workflows/pr_check.yml` analyses, tests and compiles
a pull request before it is merged, with no keys and no deploy. This
change is the first delivered as a pull request instead of a zip.

Known effects, accepted:
- A queued candidate's page starts with what Google knows (hours,
  rating, photos). The work facts (WiFi speed, plugs, calls) stay
  blank until a nomad or a founder reviews the space, as on the pages
  from the 2025 import.
- On the map a queued candidate turns from a violet "promising" pin
  into a space nobody has screened yet. The nomad whose search first
  found it gets no discovery bonus for it: that bonus is paid when a
  nomad's own review of a new space is verified.

How it was checked before the merge. The database side was run against
a local copy of the schema built from every migration in this
repository: the list and its order, both decisions, the way back, a
place queued twice, and the refusal for anyone who is not a founder.
The screen was compiled by the new check and exercised by
`candidates_tab_test.dart` against stand-ins for the database and for
Google, at a phone's width (360 and 320) in the app's font. It was not
opened against live data before the merge.

## 4 Oct 2026: Undo in Outreach

Jonathan pressed "They replied" on the wrong card. A stage could
already be set back from the three dots, but that is not where anyone
looks after a slip. Now every stage change shows **Undo** in its
confirming message for eight seconds, and a Replied card has **Did not
reply**, which returns it to Contacted (New if we never wrote). App
only: the stage is a plain field, so nothing else has to be reversed.

## 4 Oct 2026: Page upgrades goes one page at a time

Jonathan on the batch buttons: he is happy with the photos flow, but
for text he does not want batches. One page at a time, with what the
page says now next to the upgrade, and the upgrade should come from
what people search for (Ahrefs), so that a listing can compete with
other directories. Anything about structure and design is to be kept
apart, because he works through that in Webflow.

What changed (migrations 129 and 130):

- "Prepare more", "Go for all shown" and "Ask for a batch" are gone,
  with the three database functions behind them.
- "Choose a page" lists the live pages, most promising first; a page
  opens with Current and Upgraded side by side for its title, search
  description and page description, each with its own Go.
- The page title is a third text part. The template's SEO title is
  the Title Tag field, so it can be changed per page.
- "Request upgrade" asks for one page; drafts are written in a Claude
  session from Ahrefs and the space's own website and uploaded with
  what each was based on. "Write my own" and, for the search
  description, "Build from the facts" work without a session.
- What a page ranks for is loaded from Ahrefs (`page_search`) and
  counts in the order of the list.
- `docs/LISTING_TEMPLATE.md` holds the structure and design items.

Found on the way: listing pages are found almost only by the place's
name ("alchemy uluwatu", 5,300 searches a month, position 7), not by
"coworking in [city]", which the region and location pages compete
for. So a listing's title and text should serve someone checking a
place they already know. The Ahrefs project has no Search Console
data connected; connecting it would give real figures per page.
Ahrefs units used for this: about 1,650 of the month's 200,000.
## 5 Oct 2026: A zip upload overwrote another session's work

The build failed after the one-page upload (commit b494171). Cause:
the zip was packaged at 04:23 UTC from main as it stood then. At
05:05 UTC the Candidates pull request was merged, adding five methods
to `app/lib/services/supabase_service.dart` and a section to this
file. At 05:32 UTC the zip was uploaded; a file uploaded on GitHub
replaces the whole file, so both additions were lost and
`candidates_tab.dart` no longer compiled. Migrations 129
(page by page) and 130 had already been applied by then, so for a
while the database was ahead of the live app.

Fixed by merging the two versions of both files (three-way, against
the commit the zip was built from). Nothing else in the Candidates
work was touched by the upload.

For every zip from now on:

- Fetch main and merge immediately before packaging, and name the
  commit the zip was built from in the message that goes with it.
- After the upload, compare every file with main again and read the
  build log; the check on pull requests does not run for an upload
  straight to main.
- New work goes into new files where it can (a new screen, a new
  service file), so two sessions seldom need the same file.
- There are two migrations numbered 129 (`129_candidates`,
  `129_page_by_page`). They are applied by file name and define
  nothing in common, so both are in place; the next free number is
  131.

## 5 Oct 2026: Team tools from both doors

Pricing, Outreach and Page upgrades could only be opened from the
team link (nomadmaps.io/admin): the Team tools button in the control
centre's top bar was hidden when the control centre was opened from
the map's menu. Jonathan asked for both ways to lead to the same
things. The button now shows either way; "Open the map" stays only
on the team link, because from the map the back arrow already leads
there.

## 5 Oct 2026: A pointing hand on Owners, Pages, Clean-up

Hovering the three tabs at the top of the control centre showed the
typing cursor. The whole page is selectable (so a name or an address
can be copied), and the tabs were plain tap areas, so their labels
counted as text. They now show a pointing hand and are left out of
text selection. The chips and buttons were already right: Material
buttons set their own cursor.

## 5 Oct 2026: WhatsApp on a claim card opens with the question typed

The WhatsApp button under a claim waiting for a decision opened an
empty chat. It now opens with Jonathan's wording, to edit or send:
"Hi, this is Jonathan from nomadwise.io. Someone called [name] has
just claimed the [space] page on our directory. Is that you, or
someone from your team? A quick yes is all we need before we hand
over the page. Thanks!" The number is the one given on the claim
form, with the country code added when it was typed without one. The
separate "WhatsApp Google's number" button (shown when ownership is
not proven) keeps its own longer message.

## 5 Oct 2026: Arrows on the city chips in Candidates

The row of city chips in Candidates scrolled sideways only by swipe,
which a mouse cannot do. It now has the same round arrows as the
group chips above it, shown only when there is more to see in that
direction. The arrows are a small widget of their own
(`app/lib/widgets/arrow_scroll_row.dart`) so any other chip row can
use them.

## 5 Oct 2026: Products in Nomad Maps, and the price check

Jonathan's rule: the bare minimum expected of us is that a price on a
listing is the price on the space's own website, so that if a space
ever asks, we can point to their site. The Webflow Products collection
held 753 products on 153 pages, 741 of them untouched since May or
August 2025 and none ever compared with a space's website.

Asked how to handle the old prices, he chose: keep them as they are,
and add a piece in the control centre to review them one space at a
time, the check done in a session against the space's website, with
his own Go for each update. The products are to feed the Owner
account later, so a space that claims its page finds them already
there to edit.

Built (migrations 131 and 132, `scripts/webflow_products.py`,
`admin_prices_screen.dart`, `products_service.dart`; full notes in
`docs/PRICE_CHECK.md`):

- `venue_products`, our copy of every product, with the day it last
  changed on the website and the day it was last checked against the
  space's site. Loaded from the Webflow export; refreshed from Webflow
  about once a day.
- Price check, in Team tools. Request a check for a space; "Copy
  requests" for the session that does it; the result comes back as
  "the same" (stamped, nothing to press), "different", "not found",
  "no longer offered" or "new". Each change shows current next to
  proposed and has its own Go, Edit, Skip and Undo. A founder can also
  correct, add or remove a product directly.
- The website push writes an approved change to Webflow within
  minutes: only the fields the change changes, republished when the
  product is live. Taking a product off archives it; a new product
  copies the page's settings from a sibling.

Decided:

- Nothing changes on a public page without a Go on that one change. A
  product found unchanged is stamped as checked without a Go, because
  that changes nothing anyone sees.
- "Not found on their website" proposes nothing. Not finding a price
  is not proof the product ended; the founder decides.
- The push claims a change before it writes. Until it reports back,
  taking the change back or editing the product again is refused. An
  independent review found that without this the page and our copy
  could part ways (Undo pressed mid-write left the new price live and
  our copy on the old one).
- A failed report back is never recorded as a failed write: the page
  has been changed by then. The next run repeats the write, which
  changes nothing more, and records it.
- Only what a change changes is written. A price update must not put
  back details that were edited by hand in Webflow in the meantime.
- Is it safe to change a price while the old booking code is still in
  the listing template? Yes. That code keeps no price of its own: the
  reservation request quotes the price on the page, and the card
  payment path works its deposit out from the same number. A correct
  price on the page is correct everywhere.
- New work went into new files (its own screen, service file, script
  and workflow step) so it does not share files with the other
  session's Candidates work. The shared files touched are
  `website_screen.dart` and `admin_gate.dart` (a menu entry each) and
  `webflow_push.yml` (one step).

Not built yet: the product list in the Owner account (next); products
for a page that has none on the website; changing which product
carries the "starting from" price (still done in Webflow).

How it was checked: the database functions on a local Postgres built
from the migrations; the script end to end against those functions
and a stand-in for Webflow (59 checks: write, undo, a failed write, a
failed report back, an interrupted run, a hand edit in Webflow, a
short read, the daily copy). Two independent reviews, one of the SQL
and Python, one of the screen; their findings are fixed. The screen
could not be compiled here and has not been opened against live data;
the first real write to Webflow will be the first Go.

## 5 Oct 2026: The first price check, four spaces

Jonathan requested 4 WALLS Coworking, ACE Coworking Space, Alt_ChiangMai
and AT 06 (migration 133).

- 4 WALLS: all ten prices match their site. Two things on their site
  that we do not show are proposed as new: a monthly subscription and
  a Monday or Friday price for the large conference room.
- Alt_ChiangMai: sixteen of eighteen match. The meeting room for 4 and
  for 8 hours is cheaper on their site than on our page (1,200 and
  2,000 THB against 1,500 and 2,500): two changes. Monitor and locker
  rental are proposed as new.
- ACE and AT 06 have no website of their own, only Instagram, which
  cannot be read for prices. Decided: their products are marked "not
  found" with a note that says exactly that, and nothing is proposed.
  A price that cannot be confirmed is not evidence that it is wrong,
  and another directory is not a source. These two need the space to
  be asked, or a look at their Instagram by a person.

Also seen on the first day: the daily copy from Webflow ran as soon as
the workflow step was in, and the screen showed 710 products on 144
pages against 753 in the export (the export's archived listings and a
few products no longer live in Webflow).

## 5 Oct 2026: the Owner account opens with the page as it is

Jonathan, looking at PLACE Coworking Phuket's Owner account after a
free claim: the preview said "No photos yet" although the page has
photos, every day's hours read "Not set" although the page shows
Google's, and he wanted to see the page as a computer shows it too.
An owner who sees their real page is more likely to work on it.

Decided and built (migration 135, `owner_screen.dart`):

- **Phone / Computer** above the page preview. Computer lays the page
  out as the site does (main column, and hours, links, enquiry button
  and advert in a column on the right), made smaller to fit the side
  panel, with "Open full size" for reading it.
- **The page's own photos.** The preview and the form's Photos section
  show the photos on the page today (the links the nightly read keeps
  in `venue_page_facts`), until the owner adds their own. Google's
  photos are the last fallback, as before.
- **"See Accommodation options nearby" is gone from the preview.** It
  is not the owner's to change and sends people away from them.
- **Tags invite more.** Under the tags the page has, two or three that
  are not ticked show faintly; tapping opens "What is true for your
  space?", every tag with one line on what it means. Same facts as the
  form's list. "Laptop Friendly" is not offered there: every listing
  is a place to work by definition and it is not one of the ten tags
  an owner's change writes to the page.
- **Hours already known are shown.** With no hours of their own, the
  form opens with the hours Google shows (what the page shows). They
  are saved as the owner's only once a day is changed, so an untouched
  page keeps following Google.
- **Passes already on the page are shown**, in the form ("On your page
  now") and in the preview's Prices, to look at. Changing them from
  the Owner account is still to build (the product list); until then
  the form says to write to hello@nomadwise.io if one is wrong, and to
  use the four price boxes only for a pass that is not listed.
- The description box now also opens with the page's text for a brand
  new owner, before the first nightly copy has run.

Not changed: what an owner can submit, and how a change is approved.

How it was checked: the database functions on a local Postgres (hours
in Google's own punctuation, a page with and without photos, products
and text, the admin gate, and that the helper cannot be called
directly). One independent review of the screen and the SQL; its eight
findings are fixed. The screen could not be compiled here.

## 5 Oct 2026: "Your page is live" for a space the owner asked for

The email told every owner the free listing was "built from public
information". Jonathan: when a manager asked us to add the space, they
gave the first details and we added to them while checking the claim.
Decided (migration 136): for a space that came from such a request (a
claim marked as a space not listed yet) the line reads "built from the
details you sent us and what we could confirm ourselves, with a button
that sends people to you. It is in your hands now." A page that was
already listed and then claimed keeps "built from public information".
Verified is unchanged.

## 5 Oct 2026: Candidates say why, and are ordered by search demand

Jonathan: "I want to know the reason why it is a candidate ... whether
Ahrefs says it has high traffic demand ... list the cafes and coworking
spaces with the highest probability of bringing us more traffic, and
generating us revenue." Until now the list was ordered only by what
Google's reviews say about working there.

Built (migration 137, `candidates_tab.dart`, `candidate.dart`), with
the other chat's agreement that Candidates was clear to change:

- **Search numbers on each card.** How often the place's name is
  searched on Google each month (Ahrefs, worldwide, looked up 5 Oct
  2026 for the 477 candidates on the list that day), with the phrase
  that was counted, so a doubtful one can be judged: `About 870
  searches a month for "the cluster"`. A number is not shown as a
  point in the place's favour when the bare name may mean something
  else, or when Google calls the place a hotel, a hostel, a library
  and the like (those searches are for a bed or a book, not for a
  place to work; the card says "but as a hostel, not a place to
  work").
- **Gap city.** A coworking space in a city where people search for
  coworking (300 or more a month) and the site lists fewer than eight
  coworking spaces says so: "People search for coworking here and we
  list no coworking spaces". The count of what we list comes from the
  nightly read of the pages, so a page published today counts from
  tomorrow.
- **The order, "Best bets first".** Ten points for each step of name
  searches (10, 30, 100, 200, 500, 1,000 a month; five when the name
  may mean something else), six for each gap
  point (5 in a city with 1,000 or more coworking searches, 3 from
  300), eight for being a coworking space (the kind that can become a
  customer), plus the review score as before. The full rule is at the
  top of migration 137.
- **"Most searched first"** is the other order: by name searches
  alone. It puts hotels and chains on top, which is why it is not the
  default.
- **The chosen city's own numbers** show above the list: searches a
  month for coworking there, how hard Ahrefs rates it (its own bands:
  easy to 10, medium to 30, hard to 70, very hard above), and what we
  list there today.
- The same places are on the list as before. Nothing joins or leaves
  it because of the numbers.

What it does not do, and why:

- **A place found after the lookup has no name searches** until the
  next lookup. The list says how many those are. It still gets its gap
  points and its review score. A new lookup is loaded with
  `set_candidate_search()` in a migration (about 11 Ahrefs units a
  place).
- **"Do other directories list it?" is not there.** That costs about
  58 Ahrefs units a place; it was looked at for 48 candidates on 5 Oct
  and is in the project's search demand note, not on the cards.
- **How hard the place's own name is to rank for is not there**
  either. The city's difficulty is.
- **"Another branch of a place we list"** (Jonathan's Openhouse
  example) was tried on the real names and left out: of 11 matches a
  simple name rule found, 4 were right. It needs a better signal than
  the name.

How it was checked: on a local Postgres loaded with the 477 real
candidates and the real page counts (the order in five cities read by
eye; every place returned once across pages in both orders; the same
477 as the old rule; a place with no numbers; bad input to the
loaders; the admin gate). The app's own tests were extended (the
wording on cards and cities, the order switch, a narrow phone) but
could not be run here; neither could the screen be compiled. One
independent review traced every test against the code by hand and
read the SQL; its findings are fixed. The app asks the old way if the
database change has not been applied, so the list cannot go blank
over this.

## 5 Oct 2026: the Money line is a funnel, and counts real money

The line read "6 Verified, 6 paying through Stripe" when all six had
been made Verified by hand and nobody had paid: it counted every
Verified listing with a "paid on" date, and the Listing plan page
fills that date in by itself. Jonathan wants it to read left to right
as a funnel that starts with the listings claimed, to count as paying
only the listings that really pay, and to show the monthly income in
euros (MRR) and the total collected.

Built (migration 138, `scripts/stripe_money.py`, `MoneyCard` in
`control_extras.dart`):

- **Left to right:** pages claimed (and the share of the live pages
  that are claimed), Verified (the share of claimed pages that are;
  when some were made Verified on a page nobody claimed, "N of them on
  a claimed page" instead), paying through Stripe (share of the
  Verified), a month (MRR), collected so far.
- **Paying** means a subscription Stripe says is running whose last
  payment was above zero. Not counted: a listing made Verified by
  hand, a 100% promotion code, a payment refunded in full, a
  subscription that ended, a subscription Stripe no longer has, a
  payment marked "ignored" under Payments. The line under the numbers
  says how many Verified listings pay nothing.
- **A payment that failed** (Stripe's "past due") still counts while
  Stripe tries the card again, and the card says how many are in that
  state. When Stripe gives up the subscription ends and drops out.
- **MRR** is each paying subscription's last payment, a yearly one
  divided by twelve.
- **Euros** come from our own price list, not an outside exchange
  rate: a plan that costs 15 EUR and 13 GBP makes a pound worth 15/13
  of a euro. Money in a currency the price list does not have is shown
  beside the euro figure in its own currency, never guessed.
- **Collected** is everything paid with refunds taken off, before
  Stripe's fees. It needs the hourly Stripe job to read each paying
  customer's payments ("Charges and Refunds: Read" on the GitHub key,
  docs/BILLING.md). Until that is allowed, each subscription's first
  payment at the checkout stands in and the card says "some first
  payments only".
- **Money no Verified listing carries** (a payment still to match, a
  listing set back to free by hand while the subscription runs) is
  counted in the euros and said in a line of its own.
- The Stripe job's new part only reads Stripe and writes one table.
  It runs after the plans are settled and can only add a warning to
  the report, so it cannot stop a payment from making a listing
  Verified. It looks about once an hour, and at once after a new
  payment or a plan that ended.

Limits, said plainly: a customer with two subscriptions has first
payments standing in for both (nothing is counted twice; this is rare
because each checkout makes its own customer). Stripe's fees are not
taken off. The euro figure is at list-price rates, so it will differ a
little from what lands in the bank.

If none of the subscriptions is found in Stripe the key is pointing at
the wrong Stripe mode (test against live): the job then records
nothing and warns, so the card keeps what it had.

How it was checked: 83 checks on a local Postgres with a made-up cast
(by hand, monthly, yearly in pounds, a free code, lapsed, refunded,
unmatched, ignored at the start and ignored later, a failed payment
being retried, a currency with no rate, an order with no currency, a
shared customer, a subscription gone from Stripe, a claimed page that
is not live) and the real script against a stand-in for Stripe, with
and without the permission to read charges, and with the wrong mode.
Two independent reviews, their findings fixed. The card could not be
compiled here and the job has not run against the real Stripe; its
first hourly run after the upload is the first real test.

## 5 Oct 2026: Candidates open on Google, and a place to stay is kept

Jonathan: a candidate's card should open the ordinary Google page for
the place, not only Google Maps (the Map button stays). And Generator
London is a hostel: neither a cafe nor a coworking space, but worth
remembering for the "best hostels / coliving in a city" pages he wants
later.

- **Google button** on each card, before Map: searches the place's
  name, with its city added when the name does not already say it
  (`Candidate.googleQuery`).
- **"A place to stay: keep for accommodation"** is a new reason under
  "Not for the site" (second in `dismissReasons`, shared with the
  spaces' own "Not for the site"). The place leaves the list as with
  any other reason; the reason is what a later accommodation shortlist
  reads (`candidate_decisions.reason`). No database change: reasons
  are free text.

## 5 Oct 2026: a brand's searches are shared, a candidate says where it is, and how sure we are of a cafe

Jonathan, looking at Candidates under "most searched first": four
cards read "WeWork - Office Space & Coworking, London", each with
"About 2,300 searches a month for wework london". "Too generic":
nothing told the four apart, and the 2,300 belong to WeWork in London,
not to one branch. Then: "Other" should ask for a reason. Then, on
Blank Street Coffee with one mention of WiFi: "I need to be more
confident a cafe on the list is a strong likelihood as a good spot to
pull out your laptop."

Built (migration 139, `enrich_venues.py`, `candidate.dart`,
`candidates_tab.dart`):

- **Shared searches.** A search phrase given to several places, and
  for a name that only counts with its city ("starbucks porto") every
  place Google shows around under that name, is the brand's. The card
  says "shared by N places with this name" in grey, and the place is
  ordered on its share (2,300 across four is 575 each) in both orders.
  "Same name" is the name before a dash, a bar or a comma, compared
  across everything the sweeps found within about 30 km, read or not.
- **Address.** `discovered_places.address` is Google's short address.
  The nightly review scan stores it from now on (same call, same
  cost), the city sweep too, and a catch-up fills it for the places
  that can be candidates, 300 a night, with an address-only call (the
  cheapest kind, about $0.005 each at list price). The card shows
  it under the city and the Google button searches the name with it.
  Until the first nightly run after the upload the cards have none.
- **How sure the reviews make us (cafes only).** Google gives five
  reviews a place. "Strong signs people work here": two or more of
  them talk about working there. "Some": one does, or plugs and WiFi
  are both mentioned. "Thin": WiFi alone or plugs alone, which any
  cafe can get. This is honest labelling of thin evidence, not new
  evidence. What would add evidence, not built, waiting for his Go:
  asking Google's own search for "laptop friendly cafe" and "cafe to
  work from" in each city and marking the places it returns (a few
  calls a city), and a session reading the web for the short list he
  is about to queue.
- **"Reviews not read yet"** no longer shows beside a count: the map
  keeps counts without the day they were read.
- **"Other"** under "Not for the site" asks for the reason and keeps
  it as the note, on Candidates and on the spaces' own dialog. Closed
  without one, nothing is turned down.

Checked: migration 139 on the 477 real candidates in a local Postgres
(the four WeWorks drop from the top to their share; a Starbucks among
six in Porto, a Regus and a Blank Street with a second branch found;
Bastard Cafe and The Cluster untouched; applying twice; paging), the
address catch-up against stand-ins for Google and the database, and
one independent review of the Dart, the tests and the nightly job.
Not compiled here.

## 5 Oct 2026: two more kinds of evidence for a candidate (Google's search, other sites)

Jonathan said yes to asking Google's own search for places to work in
each city, and added: "review competitor websites and other leading
blogs that mention cafes and coworking spaces, and then screen them to
make sure they are still open for business." He chose London first,
and laptop-cafe directories, coworking directories and city blogs and
magazines, with the list of sites shown to him.

Built (migrations 140 and 141, `scripts/place_evidence.py` called at
the end of `enrich_venues.py`, `candidate.dart`, `candidates_tab.dart`):

- **Google's search.** For each city worked on (London to start; see
  the next entry), most searched first: "laptop friendly cafe in
  <city>" and "cafe to work from in <city>", up to three pages each. Open cafes and coworking spaces within 45 km are
  kept with the phrases that returned them
  (`discovered_places.work_phrases`); a place not known yet is added,
  so this also finds candidates. Asked again after 120 days. Libraries,
  hotels and bars are left out (found places are drawn on the map).
- **Other sites.** A session reads the sites and loads the names
  (`set_mention_sources`, `set_place_mentions(city, rows)`; names, the
  neighbourhood or address a site gives, where it was read; none of
  their text). Each name is matched to a place: free first, against the
  spaces and found places we have (same name, or the name before a
  dash); then Google is asked by name, the most named first, within
  the plan of the next entry. Google's answer also says whether it is open. Outcomes:
  listed (a space on Nomad Maps), matched (a candidate), closed, not
  found, several (a brand with several places and no branch named).
  Closed, not found and several are asked again after 120 days.
- **A closed place is never a candidate**: when Google says a named
  place has closed, the found place with that id leaves the list
  whatever its reviews said.
- **On the card:** "Named by 3 sites: Thatsup, LaptopFriendly and
  Blog" and "Google returns it for ...". A place can be on the list on
  these alone. A coworking list naming a place makes it a coworking
  space on the card, whatever Google files it under.
- **The cafe grade** now counts three kinds of sign: reviews that talk
  about working there, other sites naming it, Google's search returning
  it. Strong: one kind twice over or two kinds agreeing. Some: one of
  them once, or plugs and WiFi both. Thin: WiFi or plugs alone.
- **In "best bets first":** 4 points a phrase (two at most), 3 points
  a site (a trusted one counts double, 6 at most).
- **The line under the totals** says what became of everything the
  other sites name in the chosen city.

London, read on 5 Oct 2026: 38 sites, 1,096 mentions, 845 places (492
cafes, 354 coworking spaces; 148 named by two sites or more). Weight 2
(hand-picked lists from known publishers): Thatsup, The Infatuation,
SquareMeal, London x London, The Handbook, Time Out London, Londonist,
CBRE, Work Cafes London. Left out as too loose: Cafe Nomad, Downunder
Cafe, Workfrom. Could not be read: Coworker.com, Corner, Londonyaar.
To strike a site: `update mention_sources set weight = 0 where source
= '...'`. The full list is in the project
(`growth-engine/data/2026-10-05-london-mention-sources.csv`).

Cost: see the next entry (kept inside Google's free monthly amount).
Both parts also stop at the day's Google limit and when the job is
paused in the app, and a problem saving stops the run after at most
ten calls.

Limits, said plainly. A place matched for free was open when the
sweep found it and is checked again by the 30-day review scan, not at
the moment of matching. A name can be matched to the wrong place of a
similar name; the card shows Google's name and address so it can be
seen. A brand named without a branch (Grind, WeWork) is "several" and
credits no branch. Other cities need a session to read their sites
first.

Checked (with the next entry's changes): 92 checks on a local Postgres with the 477 real candidates
and the real script against a stand-in for Google (pages, closed,
far away, a brand, a pub of the same name, a closed place of the exact
name beside an open branch, the day's limit, Google refusing, a save
that fails, the 120-day retry), both migrations applied twice, the
London load timed with 5,000 extra places (0.2 s), and one independent
review whose findings were fixed. Not compiled here, and not run
against the real Google: the first nightly run is the first real test.

## 5 Oct 2026: the evidence job stays inside Google's free amount

Jonathan, on being told the two would cost up to about $46 at list
price: "can you reduce volume down to sit within the free allowance,
minus contingency for current traffic / activity. At the moment it's
quality over quantity, and I want to make sure we iterate and get the
flow / system / process right." Nothing had been uploaded, so the
first version never ran.

Google gives each kind of call its own free amount a month (their
pricing list, checked 5 Oct 2026: Text Search Pro 5,000, Text Search
Enterprise 1,000, Place Details Essentials 10,000, Place Details
Enterprise + Atmosphere 1,000). So:

- **One kind of call, the one with the most free room.** Every call of
  the job is a Text Search asking only for name, place, type, open or
  closed and short address: "Text Search Pro". The rating would make
  it "Enterprise", so it is no longer asked for there; the review scan
  now reads the rating on a call it already makes (same price).
- **A plan the database gives each run** (`evidence_plan()`, settings
  in `sync_settings` key `place_evidence`): at most 40 calls a day and
  1,000 a month for this job; 1,500 of the 5,000 kept back for the app
  and the other jobs; and the job stops when everyone's use of the
  kind this month, read from `api_usage`, reaches 3,500. The script
  counts its own calls and cannot make more than the plan gives.
- **Quality before quantity.** London only. A named place is looked up
  only when two sites or one trusted list give it (257 of London's
  845); the 586 named by one ordinary site are parked and said so on
  the list. The search phrases are asked for London alone (6 calls).
  London needs about 260 calls in all, about a week at 40 a day.
- **Seen and stopped from the app.** The Candidates list says how many
  lookups the month has used, of the job's 1,000 and of Google's free
  5,000. The Google calls page lists the job as "Candidate evidence"
  with its own pause switch (its calls are counted apart from the
  nightly refresh: `google_meter.switch`).
- **To widen later:** `update sync_settings set value = value ||
  '{"cities": ["London", "Lisbon"]}' where key = 'place_evidence'`;
  the same for `min_points`, `calls_per_run`, `calls_per_month`,
  `keep_back`. A new city also needs its sites read and loaded.

Said to Jonathan, not acted on: the nightly review scan (250 places a
night, "Place Details Enterprise + Atmosphere") is a kind with 1,000
free a month, so at its present pace most of it is paid for at list
price. It was there before today and is his to decide.

## 5 Oct 2026: "Choose a page" is an inbox

Jonathan: "once I've reviewed and checked and pushed with a listing, I
would like it to cycle to the bottom of the list or move into a
different section, whichever you think is best. So that there is a
kind of an inbox list of todo, so it cycles, and I can just focus on
the top of the list all the time, unless I want to search."

Both (migration 142, `admin_upgrades_screen.dart`). The list runs in
three parts: pages with a draft waiting for a Go; pages not dealt with
yet, the most promising first; pages dealt with, the longest ago
first, so the list comes round again once the rest is done. A page is
dealt with when a Go or a skip was pressed on a draft for it, when an
upgrade was requested for it, or when "Done for now" was pressed on
its card. A new draft brings it back to the top by itself; "Back to
the list" does it by hand. A new chip, "Done", shows the pages dealt
with, the latest first (a requested page stays under "Requested"
instead). Search finds any page. From the first day every page that
already had a Go or a skip is "Done".

Checked: 24 checks on a local Postgres with the real pages (done, Go,
skip, requested, a new draft, back to the list, the order at the end,
nothing lost or twice), one independent review. Not compiled here.

## 5 Oct 2026: the Price check list is an inbox too

Jonathan, on the Price check list, where the four spaces already
checked sat at the top (the list ran by name): "same with this area.
For those that have been reviewed, cycle them."

Migration 143 (`admin_prices_spaces`): changes waiting for a Go first;
then the spaces not looked at yet, by name as before; then the spaces
dealt with, the longest ago first, so the stalest check is the next
one up when the rest is done. Dealt with means: looked at against
their own website, a check requested, or a Go or a skip pressed on a
change. A new change waiting for a Go brings a space back to the top.
"Checked" shows the spaces looked at, the latest first. No button was
added: here "reviewed" is a fact the check records, not a choice.

Checked: 22 checks on a local Postgres with the real products (order
of the three parts, the cycle, Checked, requested, a new change,
nothing lost or twice), applied twice. Not compiled here (the screen
only gained a sentence).

## 5 Oct 2026: an upload no longer re-runs the night's Google work

Jonathan's phone, 5 Oct: "Google lookups at half the daily limit"
three minutes after one upload, then "Google lookups paused" (the
£10 daily limit at list prices) four minutes after the next.

Cause: `enrich.yml` starts the whole nightly job whenever
`scripts/enrich_venues.py` changes on GitHub, and two of the day's
uploads changed that file (the address catch-up, then the evidence
job). Each started a full extra night's work, mainly the review scan
(250 places a run on Google's dearest kind of lookup, about £4.70 a
run at list price) and 300 address lookups. A session had said the
evidence job would start at the upload, and missed that everything
else in the file would run again too. The daily limit did its job:
nothing was asked of Google past £10, and lookups came back at
midnight UTC.

Fix (`enrich_venues.py`): a run started by a file change
(`GITHUB_EVENT_NAME` is `push`) is a test of the code. Every part asks
Google for at most 3 (coordinates, the venue refresh, the open/closed
check, the review scan, addresses, the evidence job), and a city sweep
waits for the night. The nightly schedule and the "Run workflow"
button do the full work as before.

Rule for sessions: an upload that changes `enrich_venues.py`,
`webflow_sync.py` or `photo_suggest.py` starts that workflow. Say so
before the upload, with what it will ask of Google.

Still his to decide: the review scan itself (250 a night is about
7,500 lookups a month on a kind with 1,000 free).

## 5 Oct 2026: the review scan reads 10 places a night

Jonathan, after the day's Google limit was reached: "yes make that
change. Reduce it down to 10 a night." (30 had been suggested.)

`SIGNALS_PER_RUN` is 10 (it was 250): about 300 lookups a month on a
kind of lookup with 1,000 free, where 250 a night was about 7,500. The
ten are chosen by `review_scan_due()` (migration 144): first the places
not read yet that another site names or that Google's search returns
for a place to work; then coworking spaces not read yet; then the
other unread places, the latest found first; then places read more
than 30 days ago. A place that is already a space, or was turned down
on Candidates, is left out. Google refusing a call (a quota, a key) no
longer marks the place as read.

What it costs in speed, said to him: the 4,198 found places not read
yet would take over a year at this pace, so most of them will never be
read; the ones that reach Candidates on other signs are read first. A
place read once is looked at again only when its turn comes round,
which is no longer monthly. Places found by the evidence job get their
star rating from this scan, so about ten a night.

## 5 Oct 2026: "Next up", one thing at a time

Jonathan: "Ideally I would like to get into a rhythm of opening up the
admin panel, and to have in front of me a low brain required, where I
have something in front of me, and can make a decision on that one
thing, whether it's to add photos, or review something else, or decide
whether to list it. I'm finding it a bit tricky to look in the top
right and remember the right selection, there's a few too many
different menu options at the moment."

Asked, he chose: a "Next up" card at the top of the control centre
(not a full focus screen), and "people first, then a mix".

Built (migration 145 `admin_next_up()`, `website_screen.dart`):

- **One card, above the To do line:** the next job, why, one button
  that goes straight to it, "Skip for now", and "Then: ..." naming the
  three after it.
- **Order.** People waiting on us: enquiries, claims, payments,
  suggested updates, owner changes. Then what waits for a Go: pages to
  approve, text drafts (opens that page's review), price changes
  (opens that space). Then the other jobs take turns, one each: a new
  space, a candidate, a page short of photos, a page to look at, a
  page to finish in Webflow, a closed place, a blocked page, sitemap
  entries. The turn moves on when something is decided or the screen
  opened from the card is closed.
- **Straight to the thing.** Drafts and the page to look at open that
  one page (`UpgradePageReviewScreen`); price changes open that one
  space (`PriceSpaceScreen`); photos open the list with the most
  promising page on top; the rest jump to their group in the control
  centre, and the card folds to one line so the list has the room.
  "Look at a page" also offers "Nothing to change", which marks the
  page done without opening it.
- **Nothing else moved.** The To do line, the three sections and the
  top-right menus are as they were. The card is what makes them
  unnecessary for the daily round; trimming the menus can follow once
  the card has been lived with.

Not done, and said: decisions are not yet made on the card itself
(Queue / Not for the site on a candidate, say). The card takes him to
the place where the decision is one press away. A candidate decided
right on the card would be the next step if this works for him.

Checked: `admin_next_up()` on a local Postgres with the real pages,
products and candidates (0.2 s); migration 144's order with a made-up
cast; one independent review of the Dart, whose findings were fixed
(the card waits for its reading, folds when a job is open below, shows
what was skipped, moves on when a candidate is turned down). Not
compiled here.

## 6 Oct 2026: on a laptop the menu runs down the left

Jonathan: "If possible, on desktop can we make the top right menu
items go down the left, like how you see in Supabase and GSC and a
typical members area. Also, the items like analytics and users, I
don't use as much, also pricing, review submissions, feedback inbox...
so to have them at the bottom."

Built (`website_screen.dart`, `admin_gate.dart`): from 1,000 px wide
the control centre has a menu down its left and the two menu buttons
at the top right are gone. Top: Control centre, Page upgrades, Price
check, Outreach. Middle, "Create on nomadwise.io": Country page, City
page, Area page, Refresh from Webflow. Bottom, "Less used", smaller:
Analytics, Users, Pricing, Review submissions, Feedback inbox, and
Open the map on the team link.

- A tool opened from the menu shows beside it with the menu still
  there, the tool marked. Its back arrow, and the browser's Back, lead
  to the control centre. The pages a tool opens itself (one page's
  review, one space's prices) take the whole screen as before.
- The links that go straight to a tool (`?admin=upgrades` and the
  like) now open it the same way, so the menu is there too.
- Below 1,000 px (a phone, a narrow window) nothing changed except the
  order in the "Team tools" menu: the three used every day first, the
  five seldom used below a line.

Why tools are pushed as ordinary screens and not kept in a pane with
its own navigator: the tool screens close their dialogs with the
screen's own navigator in places, and a pane navigator would have
closed the tool instead of the dialog.

Checked: one independent review of the Dart (no compile errors found;
its four findings fixed: state kept when the window crosses the width,
the tool already showing is not restarted, linked tools get the menu,
the menu is safe after sign-out). Not compiled here, and not seen on a
screen: the widths, spacing and icons are a first cut.


## 6 Oct 2026: numbers beside the left menu

Jonathan: "for each of the left hand side menu items, can you add
numbers for each, if there are open items."

Built (`website_screen.dart`, `migration146_menu_counts.sql`): a small
number sits at the right of a menu item when something is open behind
it, and nothing when nothing is. Resting the pointer on a number says
what it counts.

- Control centre: the same total as its To do line.
- Page upgrades: drafts waiting for a Go, or needing a look.
- Price check: price changes waiting for a Go, or needing a look.
- Outreach: spaces that replied, plus follow-ups that have come due
  and have not been sent (a follow-up already sent on or after its day
  is not counted; nor is a space that claimed, verified, declined,
  unsubscribed or bounced).
- Review submissions: submissions waiting, plus photos waiting.
- Feedback inbox: messages not marked done.
- Analytics, Users, Pricing and the "Create on nomadwise.io" items
  have nothing that waits, so they never show a number.

The numbers come with the "Next up" reading (`admin_next_up()` gains a
`menu` part), so there is no extra round trip. They are read again
when the control centre reloads, when "Next up" is read again, and
when the pointer comes to the menu (at most every fifteen seconds), so
a number goes down after something is dealt with inside a tool. The
phone menu has no numbers.

Checked: the database function on the test copy (counts right, applies
twice); one independent review of the Dart, its findings fixed (the
menu is safe after sign-out, the outreach count no longer includes
follow-ups already sent). Not compiled here, and not seen on a screen.

## 6 Oct 2026: Outreach shows the spaces that have claimed

Jonathan: Outreach said "Claimed 0" while three spaces had claimed
(Westerwelle Startup Haus Arusha, Place Coworking Phuket, Kopi Club).

Why it was wrong: a contact only moved to Claimed when a claim arrived
after Outreach was built, and only when the claim's address was
already a contact's address. Spaces that claimed earlier, or with an
address we did not hold, were never in the list.

Built (`migration147_outreach_claimed.sql`): the space itself now
decides, the same way the Money card counts.

- A space with an owner on record is Claimed; on the Verified plan it
  is Verified. Its line is the one with the owner's address, or the
  one for that space; when there is none, one is made ("Claimed their
  page"). Every space that already has an owner is brought in when the
  migration runs.
- It moves when the owner is put on the space (a claim approved), not
  when a claim is merely started. A claim started and dropped no
  longer shows as Claimed.
- An owner taken off a space: the line goes to Not now with a dated
  note, so nobody is written to by accident. One owner replaced by
  another: the old owner's line does the same and lets go of the space.
- The Claimed and Verified tabs count spaces, so a space with two
  lines (its own and a person who wrote to us) is one.
- The bookkeeping never stops a claim or a payment from being saved:
  if it fails it warns and steps aside.

A Verified space shows under Verified, not Claimed. The two tabs
together are the Money card's "claimed".

## 6 Oct 2026: the path through Outreach

Jonathan: "I'm wanting to visualise the steps we're taking or can take
within this outreach section, to visualise next possible steps", with
spaces that have no address, spaces that claimed and went into their
account, how often they used it, and the steps to Verified.

Built (`migration148_outreach_path.sql`, `admin_outreach_screen.dart`,
`owner_screen.dart`, `supabase_service.dart`): a card at the top of
Outreach, "The path", in two halves, each step with how many spaces
stand on it and a bar.

- Reaching them: No address yet, Ready to write to, Written to and
  waiting, Follow-up due, Replied (and "N stepped off").
- Once they have claimed: Claimed their page, Signed in to their Owner
  account, Used it, Looked at Verified, On Verified (and "N paying",
  the Money card's number).
- Tapping a step lists its spaces below and says what can be done
  next. Under a step, a red line names the spaces stuck there
  ("2 not signed in yet", "1 changed nothing"); tapping it lists them.
- A claimed space's card says what its owner did in the Owner
  account: opened how many times, changes sent, questions answered,
  ideas, billing, and whether they opened the Verified payment step.

What was not recorded until now: an owner opening their Owner account.
From this upload every opening is counted (`owner_visits`; a reload
within half an hour is the same opening; founders are not counted).
Before it, "signed in" means a sign-in with the owner's address since
their claim, and "used it" means something they saved or sent.

Meanings, so the numbers can be trusted: "Used it" is a round of
changes, a question answered, an idea voted on or suggested, or a
billing action. "Looked at Verified" is a Verified claim started for a
space they already own and not paid. The steps are not a strict
funnel: a follow-up due can also be Written to, and a space can look
at Verified without having changed anything.

Nothing here sends anything. The "next" lines are suggestions for us.

Checked: both migrations on the test copy (each case of claiming,
leaving and replacing an owner; visit counting; every step's list;
applied twice), one independent review of the SQL (its findings fixed:
the trigger cannot block a claim or payment, replaced owners, counting
spaces not lines, sign-ins counted from the claim on) and one of the
Dart (no compile errors found; wording and tap-size findings fixed).
Not compiled here, and not seen on a screen.

## 6 Oct 2026: Candidates, the strongest one at a time

Jonathan, looking at the Candidates tab on his phone (two screens of
status text, then 587 places): "How do I improve this workflow?" and
then: "If I can be given one really strong potential, based off all of
the information and the key bits of information, so I can assess
whether to say yes to it or no. Key bits of information are if it's
listed on a bunch of different listing sites, when the reviews mention
a lot of laptop use, if it's possible to work there from a laptop, and
coworking."

Built (`candidates_tab.dart`, `candidate.dart`; no database change):

- The tab opens on "Strongest, one at a time": one place in front,
  its three key facts in the same order every time (coworking space or
  cafe; how many other sites list it, and which; how many of Google's
  five reviews mention working there), then No (with the reasons),
  Later, and "Yes, queue it". After a decision the next one is there.
  "Later" puts a place at the back for this sitting only.
- A strong candidate (`Candidate.shortlisted`): it has a city page, is
  not a hotel or the like, is not one of a chain (three or more of the
  name around), and shows signs people work there. A cafe needs strong
  signs (two reviews, two sites, both of Google's phrases, or two
  kinds agreeing). A coworking space needs one review or one other
  site, or a rating of 4.3 or more from 20 or more people.
- Order (`Candidate.strength`): other sites count most, then reviews
  about working there, then coworking, then Google's own search.
- The lines about where the list comes from (sweeps, search numbers,
  other sites, Google lookups) are behind "Details". "The full list"
  is the tab as it was, with its two orders.
- Nothing new is asked of Google: review quotes are still read only
  when "What reviews say" is pressed.

How it is picked: the database already orders the list; the app reads
up to 200 at a time and keeps the strong ones, reading on until it
has 20 in hand. The card in front never changes while more arrive.

Closed places are left as they are, by his wish: each one is retired
by hand, with its redirect and its line in the sitemap done by him
(the card's own ticks and copy buttons). No "all at once" button.

Not built from the same list of ideas, to ask about later: opening on
one city (London first) with a target, and one decision for a whole
chain.

Checked: one independent review of the Dart (no compile errors found;
its findings fixed: the list can no longer ask the database for ever,
the Yes button fits a phone, the card in front stays put, a failed
read says so). Tests added for the rule and the new view. Not
compiled here, and not seen on a screen.

## 6 Oct 2026: test accounts are marked and left out of the counts

Jonathan, on "The path" saying 12 claimed: "the number of claimed
isn't correct, as a bunch of these are test accounts so were either
me or Leonie. I need to be able to mark tests so they get excluded."

Built (`migration149_outreach_tests.sql`, `admin_outreach_screen.dart`,
`supabase_service.dart`, `control_extras.dart`):

- A card's menu in Outreach has "Mark as a test" (and "Not a test" to
  undo). A test wears a TEST chip and shows under a new "Tests" chip
  and in no other tab.
- Marking a claimed space marks the owner's address: every line of
  that space and every other space claimed with the same address
  follow. Marking a line that has not claimed marks that line only.
- Tests are left out of: the chips' numbers, "The path", the number
  beside Outreach in the menu, and the Money card's "claimed" and
  "Verified". The path says how many lines were left out, and the
  Money card how many pages. Money that was really paid still counts.
- Marked by themselves, when the migration runs and from then on as a
  line arrives or an owner is put on a space: an address at
  nomadwise.io, a founder's or team member's own sign-in address (with
  or without a +tag), and a person named just "Test" or "Test Test".
- A choice made by hand is never changed back by the automatic rules.
- The mark is about the owner. When a space's owner changes or is
  taken off, the space's own lines stop being tests, so a real claim
  on a page we once tested counts.

Not done: Analytics' "owners" view and the count of Owner account
openings do not look at the mark (a test space is left out of the path
anyway).

Checked: the migration on the test copy (applied twice; hand marks,
automatic marks, a real owner following a test owner, our own form
entries), one independent review (no compile errors or failing SQL
found; its findings fixed: a mark that outlived its owner, the first
pass made quick, a hand choice holding for the whole space, the menu's
number, the Money card's shares). Not compiled here, and not seen on a
screen.

## 6 Oct 2026: the app's icon is the Nomadwise logo

Jonathan, with the red loading screen and its pin-and-laptop icon:
"I'd like to update Nomad Maps with the logo of Nomadwise." A first
version also turned the loading screen white and put the logo beside
the name in several headers. He answered: "I liked how things were
before, but just the icon to change." So only the pictures changed;
no page and no screen was touched.

The logo is the round mark from the navigation of nomadwise.io
(`nomadwise-io-logo-red.svg` in the site's Webflow assets: red sky,
two palms, clouds, waves), cut out of that vector file so every size
is sharp. The mark is a red circle, so the icon is the mark on a white
rounded tile: on the red loading screen it sits where the old icon
sat.

Pictures replaced, same names and sizes as before:

- `app/web/icons/Icon-192.png`, `Icon-512.png` (loading screen,
  iPhone home screen), `Icon-maskable-*.png` (Android home screen),
  `app/web/favicon.png` (browser tab).
- `app/web/icons/og_square.png` (shown when a link is shared): the
  icon in the middle of the red, as before.
- `app/assets/brand/app_icon.png` (in the app: welcome box, sign-in,
  install sheet, share card) and `logo_mark.png`.
- The phone apps' icon sets (`app/ios`, `app/android`), which are not
  published today, so they do not fall behind.

Not changed: the red loading screen and its words, every header, the
pins on the map. The name stays "Nomad Maps".

A home-screen icon already added to a phone keeps the old picture
until it is removed and added again; a browser tab may keep the old
one for a while.

Checked: every picture looked at after it was made, and the loading
screen drawn in a browser here with the new icon.

## 6 Oct 2026: spaces we set up ourselves are not "claimed"

Jonathan, on SOKKOOL and Neighbors and Nomads standing in Outreach as
"Claimed their page": SOKKOOL is a booking partner (terms agreed in
person, we take bookings for them) and Neighbors and Nomads paid $25
for a listing the old way. We made both Verified ourselves. "They
technically haven't claimed their profile... so they could be in that
kind of queue": the spaces to tell that their Owner account is ready.

This replaces the rule of the entry "Outreach shows the spaces that
have claimed" above ("a space with an owner on record is Claimed").

Built (`migration150_set_up_by_us.sql`, `admin_outreach_screen.dart`):

- A space is Claimed (or Verified) when a claim of its own went
  through, or its owner has opened the Owner account or done something
  in it. Every other space with an owner on record or on the Verified
  plan is "Set up by us, not claimed yet".
- Those have their own chip in Outreach ("Set up by us"), their own
  line under "The path" with its own list, and a card that says so
  ("VERIFIED BY US" or "NOT CLAIMED YET", and "Set up by us" where it
  said "Claimed their page"). They are out of Claimed, "not signed in
  yet", Verified, and the Money card's "pages claimed".
- A space leaves the group by itself when its owner claims the page or
  opens the Owner account.
- For a space with no claim on record, a sign-in by itself does not
  count as being in the Owner account: the address may have used the
  map long before we put it on the space, and there is no date to
  count from. Opening the Owner account does count (counted since
  6 Oct 2026).
- The note on the line says "Set up by us: <space>" instead of
  "Claimed <space>", for new lines and for the ones already written.
  A claim that was dropped or turned down does not make it "Claimed".

Nothing is sent to anybody by this, and no stage moves. Writing to
these spaces waits for the framework Leonie approves.

Not done: the HQ's owners card still shows the earlier count. An
owner we put on by hand who signed in before 6 Oct 2026, and did
nothing in the Owner account, reads as "no sign of them yet".

Checked: the migration on the test copy, applied twice (the two
spaces of the screenshots, an owner put on by hand with an old map
sign-in, one who opened the Owner account, a real claim with its
address put right since, a dropped claim under the same address, a
claim that adds a new space; the Money card's "claimed" equal to the
path's). Two independent reviews (no compile errors or failing SQL
found; findings fixed: the old sign-in counting as theirs, the note's
rule too loose, the Money card). Not compiled here, and not seen on a
screen.

## 6 Oct 2026: on a phone the "Next up" card steps aside

Jonathan, with a screenshot from his phone: the card and the To do
line are frozen at the top and "it blocks, uh, prevents me from being
able to do anything on the bottom side". He likes the card; it takes
too much of a small screen.

Built (`website_screen.dart`, `candidates_tab.dart`): on a screen
narrower than 700, scrolling the list down with a finger folds the
card to one line ("NEXT UP", the job, "Show") and hides the To do
line. It comes back when the list is dragged back to its top or
pulled down there, on "Show", and when another group is opened (each
group's list now starts at its top). The Candidates list does the
same. A laptop is unchanged, and a mouse wheel never folds it.

Not done: the fold is a step, not a glide with the finger. The card is
not made smaller when open.

Checked: two independent reviews acting as the compiler (no compile
errors found; findings fixed: Candidates never folding, no way back
with a mouse, a list too short to scroll folding on an iPhone). Not
compiled here, and not seen on a phone.

## 6 Oct 2026: "Coworking" and "Cafe", one way, in candidates' names

Jonathan, on the candidate "Espacio Bica Ruzafa COWORKING": where the
word is in block capitals it should read "Coworking" by default, and
"Co-working" with a dash should read "Coworking" too. Asked whether a
name wholly in capitals should be put in ordinary capitals: "Only
words like Coworking or Cafe".

Built (`migration151_tidy_coworking_names.sql`, the function
`tidy_space_name`), applied where a candidate is shown (the list,
"Next up", the ones turned down) and where one is put in the queue, so
the page that gets made carries the tidy name:

- "COWORKING", "CoWorking", and "Co-working" with a dash in any
  capitals, read "Coworking". A name typed all in small letters keeps
  its small "coworking".
- The other words for a kind of place are put right only when in
  block capitals: Cowork, Coliving, Workspace, Space, Hub, Office,
  Cafe (and Café), Coffee, Bakery, Roasters, Kitchen, Bar, Lounge,
  Studio, Hostel, Hotel. The list is in the function; a word is added
  there.
- Nothing else in a name changes: "THE HIVE COWORKING SPACE" reads
  "THE HIVE Coworking Space", "KNOCK COFFEE BAR" reads "KNOCK Coffee
  Bar". A name may be meant to be in capitals.
- Google's answer is kept as Google gave it. The map writes to that
  table as well, and the matching of names against the listing sites
  reads it, so the name is tidied on the way out instead.
- Pages already on the site, and spaces already in the queue, keep
  their names.

Checked: on the test copy with the candidates of the earlier tests:
ten names tidied, and nothing else in any row changed; a queued
candidate's page, decision and reply carry the tidy name.

## 6 Oct 2026: the coworking numbers go to the HQ once a day

Jonathan's HQ (his private page of figures, outside this app) could
not show the coworking counts by itself: they live in this database
and nothing outside can read it. He agreed to the set-up proposed:
"Yes build the daily coworking counts so the hq reads".

Built (`migration152_hq_daily_counts.sql`):

- `hq_counts()` counts what the control centre shows: candidates
  waiting, not read yet, in London, turned down, queued; every step of
  "The path" in Outreach (including "set up by us"); every number on
  the Money card; closed places still to retire; pages live (coworking
  and cafes) and spaces in the queue.
- `hq_post_counts()` posts them to PostHog as one event,
  `hq_coworking_counts`, every day at 05:15 UTC (pg_cron), and once
  when the migration runs. The HQ's refresh reads the latest one.
- Numbers only: no name, address or email leaves the database. If a
  part cannot be counted the event carries a flag for it, not the
  error's words. The PostHog key in the migration is the map's public,
  write-only key, the one the app already carries in the browser.
- The counts are the screens' own functions, so the HQ and the control
  centre cannot disagree. Those functions answer admins only, so while
  counting the job speaks as the first admin on record, and gives the
  voice back. It reads; it writes nothing but the post.

To stop it: `select cron.unschedule('hq-coworking-counts');`.

Checked: on the test copies with the real admin check in place (the
functions refuse when called as nobody, the job counts, and they
refuse again afterwards); the post's shape. Not run against the real
PostHog from here: the first event is looked for after the upload.

## 7 Oct 2026: sending from our own inbox works with Spark on Windows

Jonathan, on the Reply box in Outreach: "this open in mail app didn't
do anything. we as a business use Spark to manage our emails". His
computer runs Windows.

Why: the button fired an email link (mailto) and trusted the
computer's default mail app to be Spark. Readdle's help page says
Spark cannot be set as the default email app on Windows, so nothing
could take the link. The box then said the draft was open when it was
not.

Changed (`admin_outreach_screen.dart`, no database change): the button
is now "From my own inbox". On Windows no link is fired: the box
offers Copy the address, Copy the subject and Copy the email, to paste
into a new email in Spark, and still asks "I sent it" afterwards. On
other computers the draft opens in the mail app as before, with the
same three copy buttons and a "try again" for when nothing opened.

Not done: a one-press draft on Windows. That would need the mailboxes'
own web page (a Gmail compose link, if the mailboxes are Google's) or
sending through the mail service itself.

Checked: one independent review acting as the compiler (no compile
errors found; its findings applied). Not compiled here, and not seen
on a screen.

## 7 Oct 2026: "Next up" stands beside the list on a wide screen, and is smaller on a phone

Jonathan, with a screenshot of the control centre on his laptop and a
green ring around the empty space to the right of the list: "can this
be moved on desktop and made smaller on mobile... if it can be moved
to the side, where the green mark is, and then for the central things
to move up".

Changed (`website_screen.dart`, no database change):

- Wide screen (1,066 or more beside the menu): the card has its own
  column, 300 wide, to the right of the list. The To do line, the
  three sections and the list start at the top. What comes after the
  job is a short list under "THEN". Beside the list the card does not
  fold to one line when a job is opened: it is in nobody's way.
- In between (a narrower laptop window): as before, the card above
  the list.
- Phone: the same card, smaller. Less space around it, a smaller
  title, the explanation cut to two lines, smaller buttons ("Skip"
  for "Skip for now"), and no "Then" line. It still folds to one line
  when the list is scrolled.

Checked: one independent review acting as the compiler and reading
the layout (no errors found; its findings applied: one shape of tree
for both widths, so widening the window does not start the list
afresh). Not compiled here, and not seen on a screen: expect a round
of tweaks to sizes.

## 7 Oct 2026: the numbers beside the menu are green

Jonathan, on the left menu: "these should be green", then "the
numbers". The count badges were the red of the item you are on, which
reads as something wrong. They are green now (`website_screen.dart`);
the item you are on stays red.

## 7 Oct 2026: who looked at claiming, to follow up

Jonathan, with the phone notice "Claim page opened: Biliq Seminyak":
"a bit like a checkout cart where they got to that point, but they
didn't do anything. And then I would like to be able to reach out...
send them a message to their WhatsApp or send them an email saying,
hey, I saw that you checked out the claim page. Did you have any
questions?"

Built (`migration153_claim_lookers_and_whole_picture.sql`,
`admin_outreach_screen.dart`, `website_screen.dart`,
`supabase_service.dart`):

- The claim page already records every visit (the `claim_*` events in
  `app_events`; our own devices are left out). `claim_lookers()` reads
  them per space for the last 60 days: when last, how often, by how
  many visitors, how far they got, for how long, from where.
- A space is "to follow up" when it is unclaimed, no claim of its is
  through or waiting for us, and its claim page was opened after we
  last wrote to it and after any "Done for now".
- In Outreach: a step on the path, "Looked at the claim page"; a gold
  line on the space's card saying what happened; Reply picks the new
  follow-up template; a WhatsApp button; "Done for now". In the
  control centre: a job in "Next up" for looks of the last two weeks,
  counted in the number beside Outreach.
- A space gets its line in Outreach the moment its claim page is
  opened (the ping makes it), and the spaces of the last 60 days got
  theirs when the migration ran.
- An address typed into a claim form left unfinished is shown on the
  card, with "Use that address" when we hold none.
- WhatsApp: the box takes the number (kept on the line; "Look the
  number up on Google" asks Google once for that place), opens
  WhatsApp with the message written, and "I sent it" records it and
  moves the card to Contacted. Nothing is sent from here.
- Two templates, an email and a WhatsApp message. The visitor is not
  known to be the owner (it can be a customer or anyone), so the words
  say "if that was you". First drafts: they are changed under
  Templates.

Nothing is sent by itself, and whether these go out at all is
Jonathan's and Leonie's call, as for every outreach email.

For later (his idea the same day, with an example from another site):
an email in a sequence to owners who claimed and were approved but
have not signed in, after 7 days or a month. Not built.

Checked: the migration on the test copy, applied twice, with made-up
visits (a look and nothing more, a form begun, our own device, a
space claimed since, a claim waiting for us, written to since, "Done
for now" and a new look after it, a WhatsApp recorded, a space with
two lines, a space picked on the bare claim page, a name that is not
on the site). Two independent reviews, of the database change and of
the screens (no compile errors and nothing that would fail found;
their findings applied: one card per space, two spaces with one name,
a line only for a space on the site, the visits read quickly, the
table fitting a phone, the WhatsApp words kept out of the email
templates). Not compiled here, and not seen on a screen.

## 7 Oct 2026: the whole picture, top down, in Outreach

Jonathan: "I don't know what the 875 places with no address yet, and
87 ready to write to relate to. Is this out of how many total
spaces... I would like to see an overall top down reconciliation... a
very clear funnel or breakdown relative to the TAM kind of thing".

Why the numbers were hard to place: "The path" counts lines in
Outreach. A line is made for every unclaimed live page, and for
everyone who wrote to us, so a space can have two, and people with no
page are in it too.

Built (`admin_outreach_whole()` in the same migration, and a card
above the path): every place we know of, each counted once, top down,
in three columns (all, coworking, cafes). Found by the nightly search
and not checked; candidates; on the map only; in the queue; live. The
live ones: closed for good, or open. The open ones: claimed, set up by
us, tests, not claimed. The unclaimed by how far Outreach has got with
the space (its furthest line): replied, written to, address known, no
address, stepped off, not in Outreach yet. Then, apart, the lines for
places with no live page. Each indented group adds up to the line
above it.

Not the market: "places we know of" is what our own searches have
found in the cities we cover, not every coworking space and cafe
there is. Candidates and unchecked places are not split by kind.

Checked: on the test copy the rows add up to the number of places, and
the columns to the total.

## 7 Oct 2026: signs of interest, in one place

Jonathan, looking at the notices on his phone (a claim page opened
from a listing; "Circles House just created an account", a business
making an ordinary account on the map, which is not a claim): "I'm
just thinking about these different routes... and how we can create a
system that either captures or engages with them... within the admin
area, in a super clear way, look at these scenarios and go, right, how
do we address this?"

Built (`migration154_signs_of_interest.sql`,
`admin_outreach_screen.dart`, `website_screen.dart`,
`supabase_service.dart`):

- Outreach has three cards at the top, one showing at a time: "Signs
  of interest" (first), "The path", "The whole picture". Whatever
  step the list is showing is said in a box under them.
- "Signs of interest" is every such scenario as a row, the warmest
  first, with how many spaces stand there now, what we know, and the
  one thing to do. Before they claim: they wrote back; began the claim
  form and stopped; made an account on the map and did not claim;
  looked at the claim page; a follow-up date has come. After they
  claim: never been in their Owner account; been in and changed
  nothing; looked at Verified and did not pay; set up by us. A row
  with nobody on it stays, greyed, so the scenario is still in view.
- New: accounts on the map that are plainly a listed, unclaimed
  space's (`signup_space_matches()`, the last 120 days). It matches on
  the address on the space's own website, an address at the website's
  own domain, the space's name as the account's name (two words or
  more, so "Charlie" the person is not Charlie's the cafe), or the
  space's name as the address's domain. A public mail domain alone
  never matches. Our own accounts and people who have claimed anything
  are left out. The card says how it matched and offers "Use that
  address"; Reply picks a new template; "Done for now" sets it aside.
  A website or a name shared by more than three spaces (a chain) does
  not match, nor does a university's or a government's website.
- When a new account matches a space the phone hears of it in a notice
  of its own within the half hour (`signup_match_sync()`, which also
  makes the space's line in Outreach). The notice for the account
  itself (migration 25) is left exactly as it was, on purpose: making
  an account must never wait on the matching, and a first version that
  put the hint into that notice could have slowed a sign-up down.
- New: "began the claim form and stopped" as its own row (the spaces
  among those who looked at the claim page whose form has an address
  typed into it). They already get one reminder by itself the next
  morning (`nudge_started_claims`, since migration 81).
- "Next up" has a job for such accounts of the last two weeks, and
  they count in the number beside Outreach.

Nothing is sent by itself. Writing to an address someone gave to make
an account, about their own space's page, is Jonathan's and Leonie's
call each time.

Not built: the reminder that goes by itself to owners who claimed and
never came in (his idea of the same day).

Checked: the migration on the test copy with made-up accounts (the
space's name on a public mail address, a one-word name that is also a
person's, the website's own domain, the address on the website, a
claimed space, a space with a claim waiting, an account older than the
window, a "website" that is a social profile, a university's website,
a chain of four, our own test address, a new account bringing its
notice once and not twice), and with a thousand spaces and two
thousand accounts (the matching takes well under a tenth of a second).
Not compiled here, and not seen on a screen.

## 7 Oct 2026: where a claim page visitor was (migration 154)

Jonathan, on the "Claim page opened" notices: "if they are in Chiang
Mai and looking in Chiang Mai, it's most likely... the actual owner.
Whereas if someone in Canada is looking at Yellow Coworking, then it's
less likely. It doesn't always be the case... I would like the
information to take account of that." And: "it's also plausible that
the user could be using a VPN, so it's never totally accurate."

- The claim page tells `claim_opened()` roughly where the visitor is:
  the country and town of the internet connection (the same lookup the
  app already makes once per visit to tell data centres apart), and
  the time zone the device's clock is set to. A VPN moves the first
  and not the second, so the two together say more than either. No
  address, and no position beyond the nearest tenth of a degree, which
  is used to measure the distance and then dropped.
- It is judged against the space (`claim_geo_judge`): "near" (the
  connection is within 60 km, or in a town the space's address names),
  "country" (the connection, or failing that the clock, is in the
  space's country), "far" (another country), or not known.
- The phone notice says it, in its title too ("Claim page opened, from
  nearby", "same country", "from abroad"), and says when the
  connection is a VPN or a data centre, and when the clock tells
  another story than the connection.
- It is kept per visit (`claim_visit_geo`: country, town, distance,
  clock's country; our own devices are left out when read, and a
  device marked internal keeps nothing). The look's card in Outreach
  shows the nearest of the visits of the two weeks up to the latest
  one, and the nearer looks come first in the list. "Next up" names
  the nearest one first. "Signs of interest" says how many of the
  looks were from the space's own area or country.
- The visits since 28 Sep were filled in from the analytics
  (connection only), so the looks already listed say where they were
  from. The ones from Denmark, which are ours, were left out.
- An app from before this (four things sent, not five) still works,
  and the server falls back to the country it saw itself.

It is a hint, never proof, and every sentence it writes says "likely"
or "less likely". Singapore in particular stands for a lot of South
East Asian traffic.

Also in this migration, from the checks of the Signs of interest
screen: the number beside Outreach counts a space once when it both
looked and made an account; the matching was rewritten so it does not
compare every account with every space; a template that is missing
falls back in turn (account, look, plain reply).

Not built: a place for a visit that began without a space (the claim
page opened from "List my space", the space picked on the page). The
notice says where the visitor was; the look's card does not.

Checked: on the test copy with made-up visits (near by distance, near
by town name, a VPN in Singapore with the clock on Bali time, another
country, same country with the clock elsewhere, only the clock known,
a data centre, no place at all, an old app, rubbish sent in, our own
device). Not compiled here, and not seen on a screen. Not checked: that
Supabase passes the country it saw (`cf-ipcountry`); if it does not,
the only loss is the fallback for old apps.

## 7 Oct 2026: a Location only when it is almost certain, and the map (migration 155)

Jonathan, on the review card of a space (Terra Cafe, Munich): "I want
to make a system on how to assign a location... it should consider
the existing locations within nomadwise, and go about a systematic
way of assigning a new one, but only if it's almost certain. It
should be something that most people would consider it to be. It also
varies depending on whether it's a city, or island, or rural
location." His words for the levels: Country, Region, Location ("the
City word isn't exactly accurate... Bali is a region and Uluwatu is a
Location"). And: "I would like to see potential other spaces nearby on
a map, because if a previous space has been assigned a location, it
makes it easier to decide... (but not always)."

- Before: the website sync gave a space the first Location whose name
  matched any of its area names, anywhere in the world, and the card
  called it "guessed, check it". Kuta on Lombok could be filed under
  Kuta on Bali.
- Now two signs are read: the area's name is a Location of the
  space's own Region; and the nearest listed places of that Region
  agree on one (two or more, and two in three, of the six nearest
  within reach). Both and the same: assigned. One, or two that
  disagree: a suggestion with "Use it". Neither: none. `docs/LOCATIONS.md`
  has the table.
- Reach by kind of Region: city 1.5 km, island 4 km, rural or wide
  area 8 km (`webflow_regions.kind`, seeded by name, changed from the
  map).
- A Location's name points to a Region only when the space can be in
  it (within 80 km of the Region's centre, or the Region's name among
  the space's area names).
- The verdict is made in the database (`location_verdict`), called by
  the sync and by the app's map, so both say the same.
- The map (`NearbySpacesScreen`): listed places around the space as
  dots coloured by Location, the verdict above, the Locations to tap
  below. Opened from the card ("Nearby spaces on a map", and a NEARBY
  cell beside Country, Region, Location).
- The sync now keeps each listed place's Region and Location ids on
  the venue, and Google's names for a queued space's area (`g_area`),
  asked once per space where it was asked on every ten-minute run.
- A space already approved keeps the Location it was approved with.
- If the sync runs before the migration is applied (an upload starts
  both), it carries on as before, only with the Region check.

A stricter rule means fewer Locations given by themselves and more
suggestions for him to take with one tap. That is the point: "only if
it's almost certain".

Not built: proposing a new Location at five places sharing an area
name (his answer: 5 places); the area names of live pages without a
Location are not collected yet, and collecting them asks Google once
per page, which is his call.

Checked: the migration on the test copy (made-up places in Munich,
Bali and Lombok: both signs, one, two that disagree, none, one
neighbour only, island reach, a space with no Region, the kind
changed, applied twice); the sync's new steps run by themselves
against made-up Regions and Locations (Kuta on Lombok, a founder's
choices, an approved space, the database not ready). The sync as a
whole was not run here, the app was not compiled, and the map was not
seen on a screen.

## 7 Oct 2026: the old booking engine's fields are left alone on a free page

Found while setting Workspace 6's booking email (now
jon@twotoneams.nl, changed in Webflow by hand with Jonathan's Go after
a real booking came through the old engine that morning).

Three Webflow fields have two meanings. For the Verified system they
are "Enquiries On" (`booking-engine`), "Listing Rank" (`booking-model`,
1 or 0) and "Enquiry Email" (`coworking-space-email-3`), and the sync
sets them whenever a listing's plan is saved or a claim goes through.
The old booking engine, still on for 11 pages, reads the same fields:
`booking-model` is its model ("Deposit") and the email is where its
bookings go. So a free claim of one of those pages would have switched
the engine off there and sent its bookings back to hello@, and the
owner of Workspace 6 had just been sent the claim link.

Now `sync_listing` keeps the three fields as they are on a page that
is not Verified and has the old engine on. The sign of the old engine
(changed later the same day): bookings are on while the page's
Verified switch is off, a pair this sync never writes. The first
version went by the model being something other than 1 or 0, and that
afternoon Jonathan set Workspace 6's model to "1" by hand, on purpose,
so customers pay the full price to Nomadwise (the page's script
charges a deposit for "Deposit" and the full price for anything
else). Verified takes the fields over as before. The run's report
lists the pages it left (`old_booking_engine_kept`).

Still open, and Jonathan's to decide: whether the old engine is back
in play at all, and what a page with it should do when it goes
Verified.

Who is copied on emails to spaces, as of today: everything Nomad Maps
sends has hello@ on it (owner emails and Outreach as a hidden copy,
passed-on enquiries as a visible one). The old engine's booking emails
do not: they go to the listing's address only, sent through the hello@
Gmail account, so a copy sits in its Sent folder and nowhere else.

## 7 Oct 2026: a claim page opened after our own message (migration 156)

The first follow-up sent from "Looked at the claim page" worked the
same day. Lisbon-Cowork's claim page had been opened on 4 Oct (from
Lisbon). Jonathan sent the WhatsApp from Outreach at 13:11, to the
number Google lists for the place (a French mobile). At 14:12 the
claim page was opened again, at 14:15 the page was claimed for free,
and he confirmed the owner.

The notice at 14:12 had it backwards: "Claim page opened, from
abroad... Looking from France, another country: less likely to be the
owner. The device's clock is on United Kingdom time." It was the
owner. Where a visitor is says little next to the fact that we had
just sent them the link.

- The claim link in anything sent from Outreach now says where it was
  sent (`from=whatsapp`, `from=email`), so a visit through it is known
  as an answer.
- A visit with no such mark that comes straight to the claim page
  within a week of our writing to the space is taken as "after our
  message" (this covers links already sent).
- For both, the notice's title says so ("from our WhatsApp", "from
  our email", "after our message"), the words say "most likely the
  person we wrote to", and the place is given as a plain fact. The
  look's card in Outreach says the same and comes first in the list.
- "Another country" is said more gently everywhere: "a weaker sign,
  though owners are often abroad", no longer "less likely to be the
  owner".
- A visit from one of our own devices says so in the notice (a device
  that has been signed in as a founder, or one marked internal).

The WhatsApp box (same day, his ask: "prefilled with their likely
WhatsApp number, or a Google link where I can then find it myself"):
when the line has no number, Google's number for the place is looked
up by itself as the box opens and kept on the line, so Google is asked
once per space; a number already on the line is never replaced by a
lookup. Under the number are links to the place's page on Google Maps,
a search for its WhatsApp, and its website and Instagram when we have
them.

Checked: migration 156 on the test copy (today's case, a link sent by
WhatsApp, by email with no place known, our own devices, an ordinary
visit, the links, the order of the list, the visits already kept), and
all the earlier tests again. The WhatsApp box was read by a reviewer
("No compile errors found"). Not compiled here.

Also on 7 Oct, from the same owner the same hour: his Owner account
would not take a one-sentence change, "The description is a little
long: 3,000 characters at most". The form opens with the page's own
text, and his page's text is longer than that. The limit is now 8,000,
in the form and in `owner_save_draft` (which had been cutting a saved
draft at 3,000 without saying so), and the form refuses a longer text
on Save draft too, so nothing is cut silently. His sentence was
changed on the page by hand that afternoon, with Jonathan's Go. A
"Claimed: how to get into their Owner account" template was added and
is the one Reply picks for a space that has claimed (it had offered
the "ready to claim" email). And Outreach now lists the line with the
latest activity first (his ask: "can you make most recent activity on
top"); before, lines with an address came first.


## 7 Oct 2026: a Share button on the map cards, before a space is screened

Miguel asked on WhatsApp: "is there no way to share a space from
Nomadmaps?" There was one, but only on the full page of a screened
space (behind "More"), so the card people actually see on the map had
none, and a space nobody has screened had none at all. Jonathan: "I
think there should be a share button before it's screened."

Both map cards (screened and not screened) now carry a small "Share"
button beside the status chip. It shares the name and a link,
`nomadmaps.io/?p=<Google place id>`, which already opens that exact
place for anyone, screened or not (`_openDeepLinkPlace`). On a phone
it opens the share sheet; on a computer it copies the link and says
so, because the browser's own share dialog there is unreliable. The
picture card stays on the full page only. The words and the link now
come from one place, `services/space_share.dart`, used by the cards
and by the full page. Counted as `space_shared` with `from: card` and
`screened: true/false`.

## 7 Oct 2026: a shared space shows its own name and picture

Miguel's feedback on the Share button, the same afternoon: the link
showed "Nomadwise Maps" and the app icon whatever was shared. "Add
rich data to the links. Name of place. Some copy: 'Hey, I want to
share [name] with you, a coworking location from Nomadmaps'."

WhatsApp and friends read a link's tags without running the app, so
every link to the app itself previews the same. Each space now has a
tiny page of its own, `nomadmaps.io/s/<Google place id>`, with its
name, where it is, its WiFi if tested, and a picture (the page's first
photo, else the first of Google's with a plain link, else the icon),
which sends a person straight on to the map at that place. They are
made at each build by `scripts/share_pages.py`: every screened space,
and the 25,000 most reviewed places nobody has screened yet. It is
called from `apply_migrations.py`, because that step has the database
at hand and runs before the web build copies `app/web`, and the
workflow file itself cannot be changed by upload. Its counts are in
`ci-debug/migrations_report.json` under `share_pages`. A place found
since the last build has no page yet: `app/web/404.html` sends
`/s/<id>` on to the map, so the link still opens, only with the plain
preview. Old `?p=` links keep working.

The message is Miguel's: "Hey, I want to share X with you, a coworking
space on Nomad Maps." ("a cafe", or "a spot" when Google calls an
unscreened place something else), with the WiFi speed when tested. On
a computer the whole message is copied, not only the link.

Not checked: how large the pictures are. WhatsApp leaves out a picture
that is too heavy, and then shows the name and line alone.

## 7 Oct 2026: "Managed by its owner" on a claimed page (migration 157)

A friend of Jonathan's saw "Claim this listing for free" on
Lisbon-Cowork an hour after its owner had claimed it. Jonathan: it
should say that it is claimed, without an owner sign-in link ("this
isn't useful or relevant to anyone viewing"), and done in the template
with conditional visibility, not with code.

The collection has no field to spare, so the mark rides in "Nomadwise
Offers" beside the owner's message (docs/OWNER_ACCOUNT.md has the two
Designer settings). The database says which pages
(`listing_has_owner`, test claims left out) and the sync writes only
that one field (`owner_marks()`), from the ten-minute run as well. A
full listing sync of every owned page was not used for the first
fill, because it also rewrites the booking fields and some of those
pages were set by hand.

Found while checking: that field was not empty everywhere. Five pages
still carried the old discount button's label, "Nomadwise Offers",
shown nowhere, and the template would have called them managed. The
migration notes the five as marked, so the sync empties the field on
those without an owner. A mark that cannot be written is tried again
six hours later, not every ten minutes.

Same migration: the end of Lisbon-Cowork's text. Its owner had saved
while the limit was still 3,000 characters, trimmed words to fit, and
the save cut the rest mid-word. Jonathan chose "only tidy the
endings": a full stop after "Tagus River", and the last sentence ends
"offers a well-balanced setup in one of Lisbon's most charming
neighborhoods." Done on the page by hand that afternoon, and in the
stored copies by the migration so his Owner account opens with it.


## 7 Oct 2026: the shared link's picture and wording, second pass (migration 158)

First look at the live links, the same afternoon. They work
(`nomadmaps.io/s/<id>` is served by GitHub Pages without the `.html`),
1,017 screened spaces and 5,206 other places got a page, and Jonathan
asked for two things.

"From Nomad Maps", not "a spot on Nomad Maps": the message now reads
"Hey, I want to share X with you, a coworking space from Nomad Maps."
("a cafe from", or just "from Nomad Maps" when what the place is is
not known). A place with "cowork" in its name counts as a coworking
space whatever Google calls it.

"Can the image be an image of the listing": 216 screened spaces had no
picture, Lisbon-Cowork among them, because the generator only looked
at photos chosen in the app. It now takes the first photo on the
space's nomadwise.io page first (`venue_page_facts`, as the nightly
sync last saw it). A place nobody has screened has no photo stored
anywhere; asking Google for one per place at build time would cost a
billed photo request each. Instead the app keeps the plain link it
already makes when somebody opens such a place's card
(`discovered_places.photo_url`, set through `discovered_photo()`, only
Google image addresses, replaced after three weeks), and the next
build puts it on the place's page. So an unscreened place gets its
picture from the first build after somebody has looked at it; until
then the app icon. Pages are only rebuilt by an upload: a nightly
rebuild is possible (the database can start the build) but was not
added without asking, since it is a ten minute build every night.

## 7 Oct 2026: a shared place's photo from the first share (migration 159)

Jonathan shared IDEA Spaces (a place nobody has screened) minutes
after opening it and asked whether the thumbnail could be one of its
photos. The app had kept the photo link (migration 158 worked), but
the place's page had been made before that, so it still showed the
icon until the next upload.

The page of an unscreened place now points its picture at a database
function, `place_photo(p)`, instead of at a fixed link. Asked for a
place, the function answers with a redirect to the photo kept for it
at that moment, sized for a preview, or to the app icon when there is
none. Whoever shares a place has its card open, and opening the card
is what keeps the photo, so the photo is there by the time the link
is sent. Nothing more is asked of Google.

The function's address needs the project's public key (the one the
app ships to every visitor; never the service key). The build step
that makes the pages is not given it and the workflow file cannot be
changed by upload, so `share_pages.py` reads it from the environment
when present and otherwise from the app as it is live on the site,
accepting only a key that says it is this project's public one.
Before using the address it tries the function once
(`lookup_works`); if anything is off, pages keep the picture known at
build time. The build's report says which under `share_pages`:
`live_picture`, and `live_picture_note` with the reason when not.

Screened spaces are unchanged: their picture is the first photo on
their nomadwise.io page, fixed at build time (1,016 of 1,017 had one
on 7 Oct).

Not checked before the upload: that Supabase passes the redirect
through as written, and that WhatsApp follows it. Both are looked at
on the live site straight after.

## 7 Oct 2026: a shared link opens its space at once

Jonathan opened a shared link (Haws Lisboa Coworking): the world map
showed for about ten seconds, then the space. "I think this is too
long."

The app opened a link's space only after two things had both come
back: the fresh list of spaces and the person's own position. The
position is a permission question in the browser, and until it is
answered or gives up nothing moved. Three changes:

- The space is looked for the moment the app starts
  (`_openDeepLinkEarly`): among the spaces remembered on the device,
  then one row from our own database (a screened space, else a place
  found before). Google is only asked, as before, when none of those
  knows the place.
- The fresh list of spaces no longer waits for the position either,
  for anyone: pins appear when the list arrives, and the position is
  applied when it comes.
- A place's share page now passes where the place is (`&at=lat,lng`),
  so the map opens there from its first frame instead of on the whole
  world. Links made before this still open, by the first change.

With no position yet, a card used to show a distance measured from
wherever the map pointed ("2,477.6 km" from the middle of the world
map; it would have read "0 m" with the change above). A card now
shows a distance only once the map knows where the person is, from
their device or roughly from their connection.

Checked on the live site the same hour: the picture of an unscreened
place is looked up when the link is shown (migration 159) and comes
back as a real photo for IDEA Spaces and Haws Lisboa.

## 7 Oct 2026: Instagram or Facebook when there is no WhatsApp (migration 160)

Jonathan, looking at "Looked at the claim page" for two cafes: "if
WhatsApp isn't available, maybe their Facebook page, or Instagram as
an option." Google's number for a cafe is often a landline, and many
have no address on record.

The box on the card now has Instagram and Facebook beside WhatsApp.
Neither lets a message be written from outside, so the dialog shows
the words (the same template as WhatsApp), and one press copies them
and opens the space's Instagram page when we hold it, or a search for
its Instagram or Facebook page when we do not (we keep no Facebook
addresses). The founder presses Message there, pastes and sends, and
comes back to "I sent it", which records it on the line as sent on
that channel (`admin_outreach_log_message`) and moves the card on.
Nothing is sent from here.

The claim link in the copied words is marked `from=instagram` or
`from=facebook`, and the notice for a visit through it now says "from
our Instagram message" (or Facebook), judged like the WhatsApp and
email links: most likely the person we wrote to, unless it came from
a data centre, which is how these services check links.

## 7 Oct 2026: a chat between an owner and Nomadwise (migration 161)

Jonathan, with a tour operator's chat in another app as the picture:
an open channel inside the Owner account, a list of the chats for him
on his phone from a link he can keep on his home screen, a notice when
somebody writes, and a record of what was said. "A great way of having
communication with cafes and coworking spaces, and eventually coliving
spaces, where there are ones that do not use WhatsApp", and in the
Owner account's menu "your inbox / support" with a number beside it
when something is unread.

One chat per space (`space_chat_messages`). His three choices:

- The owner is emailed what we write. Not at once: a job every two
  minutes sends what we wrote and they have not seen, a minute after
  the last of it, so several messages in a row make one email, and
  none goes when they are reading along in the chat. It goes through
  the same sender as the other owner emails, so hello@ gets its copy.
  An answer sent by email reaches hello@, not the chat (taking email
  answers into the chat needs an inbound address set up at Postmark:
  possible, not built).
- Our messages are signed with the founder's first name, from their
  profile ("Jonathan from Nomadwise"); "Nomadwise" when there is none.
- Either side can start. The founders' list shows every space with an
  owner, the chats waiting for an answer first.

The owner's side is a new tab in the Owner account, "Inbox & support",
with the number of unread messages beside it (looked up every 45
seconds, and as the chat is opened). The founders' side is the Chats
screen: in the team menus with its own number, and by itself at
nomadmaps.io/chats, which opens only the chats so it is quick on a
phone. Both sides use one widget (`widgets/chat_thread.dart`): theirs
on the left, yours on the right, "Today at 17:43" under each, one tick
for sent and two once the other side has opened the chat, a short
note above the box. It looks again every eight seconds while open;
nothing is pushed.

The founders' phones are told when an owner writes (`chat_notify`),
and tapping the notice opens the chats. The notice says who wrote and
for which space, never what they wrote: it travels through a public
notice service, and an owner's words stay in our own database. The
home-screen icon is made
from nomadmaps.io/chats/?add: that page has no app manifest on
purpose, so on an iPhone the icon opens in Safari, where the founder
is already signed in (an installed web app keeps its own sign-in).

A chat belongs to the owner it was had with, not only to the space.
Each message keeps the owner's address it was written to or by
(`owner_email`), and an owner sees only their own. So when a space
changes hands the new owner opens an empty chat and is not emailed
what we wrote to the one before; the founders still see the whole
history for the space. Found in review before it shipped.

Also settled in review: the email job marks and reads its messages in
one step, so two runs cannot send the same email twice or mark one
without sending it; an owner can send 40 messages an hour, counted
under a lock; the chat does not ask the server again while its browser
tab is hidden, so a message is not shown as read by a tab nobody is
looking at; Enter sends on a computer and makes a new line on a phone.

The email's button, and both ways of signing in to the Owner account
(the emailed link and Google), carry `?chat=<space>`, so an owner who
has to sign in first still lands in that chat.

Not in this first version: photos in a chat, closing a chat, a chat
button on the Outreach card, email answers arriving in the chat.

## 7 Oct 2026: an owner's answer by email arrives in the chat (migration 162)

Jonathan, the same evening as the chat: "Can we setup an inbound in
postmark". Until now an owner who answered the email that says we
wrote reached hello@ and the chat stayed silent.

How it works. Postmark gives the mail server an inbound address and
hands every email that arrives there to a web address of ours (its
"inbound webhook"). Each chat, a space and its owner, has a key of its
own (`chat_reply_tokens`). The email that says we wrote carries
Reply-To: `<inbound address>+<key>@...`, so the answer itself says
which chat it belongs to. `chat_inbound` takes the new words out of
the email, puts them in the chat as the owner's message (marked "by
email" under the bubble), marks what we emailed as seen, and tells the
founders' phones.

Switched on by two things Jonathan does by hand, and nothing changes
until both are done (emails keep their old ending and answers keep
reaching hello@):

1. In Postmark, on the server that sends our email: the inbound
   stream's webhook is set to
   `https://<project>.supabase.co/rest/v1/rpc/chat_inbound?apikey=<the app's public key>`.
   The key in that address is the public one the app itself ships
   with, not a secret. If that key is ever changed in Supabase, this
   address has to be changed with it.
2. In Supabase Vault: a secret named `chat_inbound_address` holding
   the inbound address Postmark shows. To use an address of our own
   later (for example at reply.nomadmaps.io, by a mail record that
   points to Postmark), only this value changes.

No function in between: PostgREST passes the whole of Postmark's JSON
to a database function with one unnamed jsonb parameter. Checked on
the live project before building: a call with the key only in the
address is accepted, and the server looks for exactly that kind of
function.

What the key is for. Anybody can call the webhook (the public key is
public), so the key in the address is the only proof, and an email
without one we gave out never becomes a chat message, whoever it says
it is from. Such emails are logged in `chat_inbound_log` (30 an hour
kept, 7 days), and counted apart from owners' answers so a flood of
them cannot stand in the way. The phones hear about one only when the
sender is a known owner, once a day for each sender and five times a
day in all, without any words the sender chose.

Kept out of the chat, each with its line in the log: automatic
answers (out of office, bounces), one of us answering the copy hello@
gets, an email for a space that has changed hands (the phones are
told), an email with nothing new in it, more than 40 messages an hour
for one space (the same count as in the Owner account), and a second
delivery of the same email. Whatever goes wrong, the webhook answers
"ok": an error would only make Postmark deliver the email again.

Finding the new words (`chat_reply_text`): Postmark's own cut when it
has one, then a cut at the first sign of a quoted message ("On 7 Oct
2026 ... wrote:" and its French, Spanish, Portuguese, German, Italian
and Dutch forms, the header block other mail programs use, lines that
start with ">", the line that names hello@, our own email quoted
without marks, a signature mark). A line like "On Google a guest
wrote:" in the owner's own words is not a quote header: those have a
date in them. Answers written under or between the quoted lines are
kept. Files are not carried over: the message says how many came, and
they can be seen in Postmark under the inbound stream (a small picture
inside a signature is not counted). Long emails are cut at 3,700
characters with a line that says so.

Two doors found open while this was checked, closed in the same
migration. Every function in the public schema can be called through
the API by anybody with the app's public key unless that is taken
away. For `send_owner_email` (migration 101) and `notify_phone`
(migration 25) it never was: anybody could have sent an email from
hello@ to any address with any words, or a notice to the founders'
phones. Confirmed on the live project for `send_owner_email` (a call
with an empty address, which stops at its first line, was accepted);
`notify_phone` was not tried, since trying it rings the phones. Both
are now for the database's own functions and the service key only;
every function that calls them runs with the owner's rights, and
`stripe_sync.py` uses the service key, so nothing that works today
stops working. Still to be read one by one, because the same default
applies to them and each needs a look at who calls it (the website's
own pages call some of these, so none was closed blind):
`nudge_github`, `nudge_started_claims`, `send_enquiry`,
`check_api_alerts`, `api_alert_once`, `summarize_quiet_visitors`,
`mark_owner_email`, `outreach_match_venue`, `report_stale_photos`.

Checked: the migration applied twice on the test copy; some fifty
emails of different shapes sent through a local copy of the API
server; a second reader's attack cases (slow patterns, floods, forged
senders), all fixed before shipping. Not seen with a real email yet:
that is the first thing to try after the two steps above.

## 7 Oct 2026: Outreach emails to claimed spaces in the same look as the others (migration 163)

Jonathan, with the chat email (in its card under "nomadwise FOR
SPACES") and an Outreach email ("Your Owner account for ...", bare
text) next to each other in his inbox: "I want it to be the same as
how the nomadwise for spaces email is styled."

Outreach emails sent through Postmark went out as text only since
migration 121, on purpose: a plain email reads as one person writing
to another. Told that a designed email to a space that does not know
us is more likely to be filed under Promotions, he drew the line:
"lets not do the branded look for first contact emails".

So the rule is by where the contact stands:

- **Claimed or verified** (they have an Owner account): the email
  carries the designed version, made by the same function as every
  other email to a space (`owner_email_html`), so a change to the
  look changes all of them at once. The plain text still travels with
  it. The unsubscribe line reads "If you would rather not hear from
  us again, unsubscribe here." with the address behind the last two
  words, as the small grey line at the foot of the card.
- **Everybody else** (a first email, a follow-up to somebody who has
  not answered, an answer to somebody who wrote to us): plain text,
  exactly as before.

The words are the template's in both cases. Not changed: emails sent
from the founder's own inbox (the other Outreach route), which are
written in that mail program.

Also seen that evening, the first real run of the chat by email: the
owner's answer by email arrived in the chat within seconds with the
quoted email taken off, and our two messages got their two ticks.
The first chat email had been refused by Postmark (the server token
in the Vault was being replaced at that moment); an email Postmark
refuses is not sent again by itself, which is still open.

## 8 Oct 2026: a crawler's networks are blocked (migration 164)

Early on 8 Oct the founders' phones said "Claim page opened" 17 times
between 05:17 and 06:45 London time, each time "from
nomadwise.io/blog/...", "Looking from Singapore. The device's clock is
on China time." PostHog showed what it was: a crawler on Tencent's
cloud servers in Singapore (43.172.x.x and 43.173.x.x, AS132203),
following the claim links on one nomadwise.io page after another. No
referrer, a desktop browser on China time, a new visitor id each
visit, and a new address every few seconds: one visit's three steps
came from three addresses within two seconds. Nothing from that
network in the three weeks before. Among them, two real visits: a
phone in Tallinn from the Workland Fahle page, and an Android phone
on the nomadwise.io home page.

Jonathan: "I want both" (no notices or counts for such visits, and
PostHog told it is a bot), and "Is it also possible to block this
activity as soon as it's identified".

- **PostHog** (done by hand the same morning, with his go): a custom
  bot rule "Tencent Cloud crawler (Singapore)", $ip in 43.172.0.0/15,
  category headless_browser. Its 25 events of that morning then read
  as Automation.
- **Blocked networks** (`blocked_networks`), seeded with
  43.172.0.0/15. A claim visit or an app event from a blocked network
  is not stored and tells nobody; the app asks once per visit
  (`visit_blocked`) and then sends nothing, PostHog included.
- **As soon as one gives itself away:** one visitor whose requests
  come from three different /24 networks within two minutes is a
  machine with a pool of addresses (a phone moving between wifi and
  mobile data makes two). Its /16 networks are blocked for 90 days and
  the phones say "A bot was blocked" once. The addresses this needs
  are kept ten to twenty minutes and then deleted.
- **Only Cloudflare's address is believed** (`cf-connecting-ip`): the
  other address headers can be written by the caller, who could then
  get somebody else's network blocked. If the database cannot read the
  address, nothing is checked and nothing is blocked;
  `admin_bot_guard()` says which, and lists the networks.
- **What blocking cannot do:** the claim page is a static page on
  GitHub Pages and is served to anybody; refusing the visit at the
  door would need a service like Cloudflare in front of nomadmaps.io.
  Claiming is never blocked: an owner on such a network can still
  claim, and that is still announced.
- **That morning's rows** were moved out of claim_visits, app_events
  and claim_visit_geo into `blocked_rows` (kept, not thrown away).
  Three had become signs of interest in Outreach: Tribal Bali,
  Hellocapitano Lifestyle Cafe, Indigo Specialty Coffee & Bakery.

If "A bot was blocked" ever names a network that looks like real
people (a mobile network, a relay such as iCloud Private Relay), the
block is lifted by deleting its line from `blocked_networks`.

Checked live the same morning: the database reads the visitor's
address (`address_readable` true), and the crawler came back after the
upload: 13 requests from 43.172.0.0/15 between 07:16 and 07:54 London
time were turned away (no notices, nothing stored). Its first events
still reached PostHog (marked as a bot there by the rule): the app gave
up waiting for the "blocked" answer after 1.5 seconds. It now waits up
to five seconds, and a later answer still silences the rest of the
visit.

## 8 Oct 2026: no "facts" anywhere an owner reads (migrations 165, 166)

Jonathan: "can we change this template to not say "facts"", then "any
reference to "facts" to be changed please". What an owner can change
is now named: "update your opening hours and contact details" (Outreach
templates, migration 165), "update your contact details" (the claim
emails, migration 166), "Update your details: hours, prices, WiFi and
contact" (claim page), "amenities" for the yes/no list of what a space
offers for work (Owner account, the team's space editor, the space
trail, the story card), "the details and photos are yours" (Owner
account, nomadmaps.io/spaces), and "Build from the details" in Page
upgrades. The data keeps its own name (`facts`, `venue_page_facts`):
only words people read changed. The live nomadwise.io pages checked
(a coworking page, the coworking list, the home page, the old "add my
business" page) had no "facts" in them.


## 8 Oct 2026: sign-in reminders as a Sequence (migration 167)

Jonathan: a "super friendly reminder" for spaces that claimed but never
signed in, then "clearly illustrate it within the Nomad Maps admin
area ... what spaces are included in sequencing and what the sequencing
route is and also for the ability for us to switch that off ... either
all together or for each individual email or listing". Chosen: two
emails, day 7 and day 21, with the wording he approved.

Who: a space claimed by its owner (not a test), with the claim
approved, never signed in to the Owner account. Email 1 goes 7 days
after the claim (and at least 2 days after approval); email 2 goes 21
days after the claim (and at least 10 days after email 1). Signing in
at any point takes the space out. Each email goes to a space once,
whatever happens (`sequence_sends`). Runs every morning at 09:10
London time (cron `signin-reminders`), with one phone notice listing
what went.

Switches, in Control centre > Sequences: the whole sequence, each
email, and each space. All start on. The tables are `sequences`,
`sequence_steps` and `sequence_exclusions`, so a later sequence can
reuse the same screen.

Also in 167: link-checkers at owners' mail providers open the claim
link with a scrambled code (a "From email/WhatsApp" visit to an
unknown claim page). Those no longer send a phone notice. A real
claim link always matches a space, so real owners still notify.

## 8 Oct 2026: Country picker on New spaces cards

Jonathan: "country doesnt have a dropdown like region and location
have". COUNTRY is now tappable like REGION and LOCATION, picking from
the site's Countries; the choice is saved on the space. The Region
picker then lists that Country's Regions first.

## 8 Oct 2026: no "finished a visit" phone notices (migration 168)

Jonathan: not useful when it pings his phone. The 5-minute job
`summarize-visitors` (migration 27) is stopped; the function stays so
it can be switched back on with one line (in the migration's header).
Other phone notices are unchanged.

## 8 Oct 2026: Ask Claude which Location (migration 169)

Jonathan, on the map of nearby spaces: "maybe its possible to run a
search to ask claude or google to check" (he chose Claude), then
"giving me a choice would be great ... and then if you can learn each
time so that over time you get it more right", and "I could even
provide a reason why I selected the option I chose."

On the map screen, "Ask Claude" sends the space's position, Google's
names for its area, the Region's Locations, the Region's listed places
with their Locations, and his earlier choices with his reasons. Claude
offers up to three options (an existing Location, or a well-known
area name to create as a new one), each with a reason; no options
means the Region page alone. He picks one, may write why, and that is
kept (`location_asks`). Later questions in the same Region carry his
choices; the ones where he went against Claude's first option are
sent for every Region. That is how it learns: from his decisions, not
from a model being retrained.

Needs a Claude API key in the Supabase Vault as `anthropic_api_key`
(he adds it). Model `claude-sonnet-4-5` unless a Vault entry
`anthropic_model` says otherwise. Capped at 50 questions a day.
Choosing a new Location opens the usual new-Location page, filled in,
and the space waits for it.

Also: a Region with no Locations now says so on the map, instead of
"Nothing points to a Location".

## 8 Oct 2026: clearer "When" on Sequences (migration 170)

Jonathan asked what "with a copy to hello@" meant. It now says: sent
from hello@nomadwise.io, with a hidden copy of each email in that
inbox so there is a record of what went.

## 8 Oct 2026: Outreach, one card per space, and what it was about (migration 171)

Jonathan: "why are there 2 boxes here for the same space?" (Lisbon
Cowork) and, on Sierra Cartel's GST thread, that some imported trails
are not relevant to outreach. He chose all of the following.

- One card per space. A line Outreach made by itself for a space
  (source listing or claim, nothing ever received on it) is folded
  into the space's other card, every night (cron `outreach-fold`).
  Seven pairs written to from two addresses were joined by hand:
  Lisbon Cowork, KAPTAR, The Work Loft, Ofis Voyvoda, Nomio, Monday,
  ViOS. Avila (two locations) and Selina (several teams and places)
  were left as they are. A second address goes into the notes.
- A topic on each card, set for the 85 from the inbox and forms by
  reading each trail: Listing, Booking, Partnership, Other business,
  Removed or not a fit, User recommendation. Changeable from the card
  menu ("What it was about").
- Other business and Removed or not a fit are set aside under the
  chip "Not for outreach", out of the list and the numbers, still
  found by searching. A space that has claimed or pays is never set
  aside.
- New template `reply_we_know_you` for spaces known from a booking or
  partnership, picked first for those when they are on the site.

## 8 Oct 2026: our own new spaces go straight on; Candidates search (migration 172)

"Life According to KAWA" (added by Jonathan on the spot in Dubrovnik)
never reached the Pages tabs: its review was recorded as Rejected (the
Reject button sits beside Approve), so the space stayed hidden. It was
approved by hand the same morning with his Go. Now a new space added
by a founder or a team member is approved as it is saved, and Reject
in Review submissions asks first. Candidates has a search box that
filters as you type (name, address or city; admin_candidates p_q).

## 8 Oct 2026: live pages without a Location (migration 173)

Jonathan asked for one place to work through every live page with no
Location. Control centre > Clean-up > No Location lists them (40 on
8 Oct) with the suggestion where there is one. For each: use the
suggestion, choose on the map (with Ask Claude) or from the list,
make a new Location, or mark that no Location is fine (kept as
`website_location_override = 'none'`, with Undo). A chosen Location is
set on the Webflow item and the item published again by the website
sync (`website_location_apply`); a new one is linked once it exists
(`website_new_location`). Every change to a live page starts from a
founder's press that first says exactly what changes.

## 8 Oct 2026: small unsubscribe line in plain Outreach emails (migration 174)

Jonathan: "the unsubscribe link should be styled and smaller and a
shorter link". Plain Outreach emails (to spaces that have not claimed)
now carry an HTML version that still looks like a personal email (no
logo, card, pictures or buttons), with the last line in small grey
type: "If you would rather not hear from us again, unsubscribe here."
The address sits behind "unsubscribe here". Claimed spaces keep the
designed card (migration 163).

## 8 Oct 2026: a lighter map, to stay inside the data allowance (migration 175)

Supabase: 6.65 GB sent of the free plan's 5 GB this cycle (grace
period until 7 Nov 2026). Measured: each map open read every column
of every space, about 15 MB (3.7 MB compressed), mostly Google's full
answer per place, links to all its photos and the nightly photo
notes. About 75 opens a day made the total.

Now the map asks map_venues(): the columns it reads, Google's answer
cut to what the app shows, and one photo per space (no 1,000-row cut
either: 22 spaces had been missing from the map). A card or a space's
page asks for that one space in full when opened, so photos are as
before. A copy fetched in the last 20 minutes on the same device is
used as it is. Measured on the live data: about a quarter of the
compressed size, and repeat opens within 20 minutes send nothing.

## 9 Oct 2026: crawler gets an empty map; founders' devices are ours; failed sends retried (migrations 176, 177)

- map_venues() answers a visit from a blocked network (the Singapore
  crawler, migration 164) with an empty list, so it no longer spends
  the data allowance.
- A device where a founder signs in marks itself as a team device:
  it sends no analytics from then on (as nomadmaps.io/#internal) and
  is added to team_devices. Jonathan's phone was added by hand.
  nomadmaps.io/#public lifts it on a device.
- Owner emails keep the exact payload sent. Every 20 minutes a send
  that failed on the way (timeout, no answer, 429, 5xx) is tried again
  as it was, up to three tries within six hours. Refusals that would
  repeat (bad or inactive address) are not retried.

## 9 Oct 2026: New spaces cards show photos; new pages join Outreach (migration 178)

1. Jonathan, on Control centre > Pages > New spaces: "this isn't giving
   me understanding that i can update the photos". Each New spaces card
   now has a photos line under Country / Region / Location / Nearby,
   with Add photos (or the chosen photos and Edit photos). Photos
   picked before queueing are kept: the suggestion step only fills in
   photos when none were chosen.
2. Jonathan, on Level39 (shortlisted, approved, published 9 Oct): a
   page we approve should reach cold outreach, with an address when one
   can be found, to test how many go on to claim and sign in. Until now
   such a space reached Outreach only through "Bring in listed spaces".
   Now venues.new_page_live_at is set when an approved page is marked
   released, a trigger makes its Outreach line the way "Bring in listed
   spaces" does, its website is read for an address before the others,
   and Outreach opens on a New pages card that counts live, address,
   written to, opened the claim page, claimed, been in the Owner
   account. Nothing is sent by itself; the hello is written by hand
   (template invite_new_page). Pages approved since 6 Oct 2026 and live
   already are counted from when the migration ran.
   Leonie has not yet approved the outreach framework; sending this
   first hello is Jonathan's own test.
3. The address finder (webflow_enquiries.py) now prefers community@,
   members@, enquiries@ and similar, and tries press, careers, events,
   accounts and personal first.last addresses last. On Level39's
   contact page that picks community@level39.co (general enquiries).

Checked: migration 178 applied twice on the test copy; a page going
live got one line (and only one on the next sync run), an owned page
got none, a page never approved in Pages was left out, the address found
afterwards reached the line, and the count followed it through written
to and claimed. Dart reviewed by reading (no SDK here).

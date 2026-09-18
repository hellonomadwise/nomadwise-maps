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

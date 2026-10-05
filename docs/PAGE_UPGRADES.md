# Page upgrades: listing pages improved one page at a time

Control centre, Team tools menu, **Page upgrades** (or
`nomadmaps.io/?admin=upgrades`). Migrations 125 to 130.

## What it is

A way to improve the listing pages on nomadwise.io one page at a time.
A founder picks a page, sees what it says now next to the upgrade, and
presses **Go** for each part himself. Nothing reaches the website
without that.

It exists because most pages are thin. On 4 Oct 2026, 246 of the 338
coworking pages had no description, and 1,009 of the 1,011 live pages
shared one generic search description.

There are no batches. Until migration 129 the screen could prepare
search descriptions by the hundred and approve a screenful at once;
Jonathan asked for that to go (4 Oct 2026), and the three functions
behind it were dropped.

## The parts of a page

| Part | What it changes | Webflow field |
|---|---|---|
| Page title | The headline Google shows, and the browser tab | Title Tag (the template's SEO title is this field) |
| Search description | The line Google shows under the headline | Meta Description |
| Page description | The text of the page | More Info (price lines stay underneath) |
| Photos | The five pictures | the page's Images entry (see Photos below) |

The layout, headings and structured data of the page are not parts:
they are one change in the Webflow template for every page, and are
kept in `docs/LISTING_TEMPLATE.md`.

## Choose a page

**Choose a page** lists every live page, the most promising first.
The score is built from:

- page views of that listing page in the last 90 days;
- how many Google reviews the place has;
- what the page already ranks for on Google: a page sitting between
  position 2 and 30 for a search people make has the most to gain;
- a quarter more for a coworking space than for a cafe.

The reason is on every row, for example "33 page views in 90 days ·
cafe · 2,836 Google reviews · position 7 on Google for "alchemy
uluwatu" (5,300 searches a month)". The chips above the list narrow it
to pages searched for on Google, pages that have been requested, and
pages with a draft waiting.

## One page

Opening a page shows, for the title, the search description and the
page description:

- **Current** on the left: what the page says now, as the nightly sync
  last read it.
- **Upgraded** on the right: the draft, if there is one, with a line
  saying what it was based on.
- Its own **Go**, **Edit** and **Skip**. Taking the title and leaving
  the rest is fine.

Above them is what people search on Google to find the page (from
Ahrefs), and the request box.

Three ways an upgrade gets there:

1. **Request upgrade**: the page is put on the list to be drafted (see
   below). The drafts come back to the page.
2. **Write my own**: any part can be written by hand. Saving is the
   Go, as with photos.
3. **Build from the facts** (search description only): a plain line
   made from what we hold about the place, for example "Revolver Canggu
   is a cafe to work from in Canggu, Bali. WiFi at 87 Mbps, plenty of
   plug sockets and aircon. Rated 4.6 on Google." It is a proposal to
   check; nothing is sent until Go.

A newer draft replaces one that was still waiting. One that is already
live is kept as history (status `superseded`) and the new one waits in
its place.

## How a requested page gets drafted

The app cannot reach Ahrefs or write text by itself; drafting happens
in a Claude session, one page at a time.

1. A founder presses **Request upgrade** on a page, with an optional
   note. **Copy requests** on the list of pages puts the open requests
   on the clipboard (name, page address, note) to paste into the
   session. They are also in the nightly sync report on the
   `sync-reports` branch, under `upgrades.page_requests`.
2. For each page, in the session:
   - what the page says now (Webflow: Title Tag, Meta Description,
     More Info, H1 Label);
   - what it ranks for and how often that is searched (Ahrefs, organic
     keywords for the page address);
   - how much the space's name and "coworking in [area]" are searched,
     and which pages hold the top results for the name (Ahrefs);
   - the space's own website, for what is true about the place.
3. The title, search description and page description are written
   from that. Nothing is claimed that the space's own site or the
   facts we hold do not support.
4. A migration is produced that calls `import_page_upgrades('[{"slug":
   ..., "kind": "title" | "search_description" | "description", "text":
   ..., "note": "what it was based on"}]', '<name>')`, and is uploaded
   like any other change. The drafts appear on the page and under
   **Waiting for your Go**, and the request is closed.

What a page ranks for (`page_search`) and the page views
(`page_popularity`) are refreshed the same way, by a migration calling
`set_page_search()` or `set_page_popularity()`.

The first load of search data (migration 130, 4 Oct 2026) holds every
search of 40 or more a month for which a listing page is in Google's
first 30 results: 89 rows for 69 pages. Nearly all are searches for a
place by its name, which is what the upgrades aim at.

## Photos

A page holds five photos. On 4 Oct 2026, 597 of the 1,011 live pages
had fewer, 378 of them a single one; nearly all are cafes.

**Add photos** on the Photos row opens the list of pages short of
five, the most visited first. **Add photos** on a page's card opens
the same photo page a new listing uses: the photos on the page now sit
in the slots, "Open on Google" and "Photos on Google Maps" open the
place, and an image address copied there (right-click a photo, "Copy
image address") goes into a free slot. The first slot is the main
picture.

Saving is the Go. The list is stored as an approved upgrade, the push
writes the changed slots into the page's Images entry, sets the big
photo grid when there are four or more, and republishes. It then
shows under On its way and Live like any other upgrade, and Undo puts
the earlier photos back. A page can be topped up again later; the
earlier change is kept as history (status `superseded`) and can no
longer be undone from the screen, only the latest one can.

"Photos on Google Maps" is offered from the list of pages short of
photos. **Edit** on a queue card opens the same photo page with "Open
on Google" only.

Two safeguards: if the photos on the page changed between opening the
photo page and saving, the save is refused and the list is reloaded;
and a page whose owner has added photos in the Owner account is left
out of the list and refused, so a founder's paste never replaces an
owner's pictures.

Nothing is fetched from Google by the app for this: the founder
copies the image addresses by hand, as for new listings.

## Buttons

- **Go**: approves the upgrade. The website push writes it and
  republishes the page within minutes.
- **Edit**: change the words, then "Go with this wording".
- **Skip**: not this one. It stays as history and can be brought back.
- **Take back** (On its way): stops a change the push has not started
  writing. Once the push has claimed it, Take back is refused for a
  few minutes; use Undo after that.
- **Undo** (Live): the push puts back exactly what the page had
  before. That is recorded when the push first claims the change, so a
  retry after a failed write cannot lose it.
- **Bring back**: returns a skipped or undone upgrade to waiting.

The queue under "Every change, by where it stands" shows the same
upgrades as cards (Waiting for your Go, On its way, Live, Needs a
look, Skipped), each with Current and Upgraded side by side.

A change that the website refuses lands on **Needs a look** with the
reason, and can be tried again.

## What it leaves alone

- A page with an owner keeps the description its owner wrote: drafted
  descriptions are not loaded for owned pages, and one approved before
  the page was claimed is refused at the last step. An Undo of a
  description is refused in the same way once the page has an owner.
- Price lines the sync wrote into More Info stay under a new
  description.
- One live change per page and part at a time.
- The layout of the page: see `docs/LISTING_TEMPLATE.md`.
- No long dashes, and no HTML: a line starting `## ` is a heading,
  the rest are paragraphs.

## Where things live

| Thing | Where |
|---|---|
| Queue | `page_upgrades` (status: proposed, approved, applied, skipped, failed, undo_requested, undone, superseded) |
| Requests | `upgrade_requests` (one open request per page, `venue_id`) |
| What a page ranks for | `page_search` (slug, keyword, country, position, volume), from Ahrefs |
| Page views | `page_popularity` (slug, views, visitors, days) |
| Photos on each page | `venue_page_facts` (`photos`, `photo_urls`): seeded by migration 128, refreshed nightly from the Images collection, and updated straight after each photo write or undo |
| What each page holds | `venue_page_facts`, written nightly by `scripts/webflow_sync.py` (its own table, so the map's read of `venues` does not carry it) |
| Writing to Webflow | `scripts/webflow_sync.py`, "page upgrades" section, in the ten-minute push and the nightly run |
| Screen | `app/lib/screens/admin_upgrades_screen.dart` (the queue, Choose a page, one page, pages short of photos) |

## Limits to know

- Page views come from PostHog and count nomadwise.io only, with bots
  left out. A page nobody visited scores on its Google reviews alone.
- "Current" is what the nightly sync last read, kept up to date by
  the changes made here. A page edited by hand in Webflow shows its
  new text from the next morning. Until a page has been read by the
  sync that keeps titles and page text (the first run after migration
  129), its title and description show as "Not read from the website
  yet".
- What a page ranks for comes from Ahrefs, not from Google itself:
  it covers the searches Ahrefs tracks, the number of searches is for
  the one country shown, and a page missing from it may still get
  visits from Google. Connecting Search Console to the Ahrefs project
  would give real figures for every page.
- Google does not always show the title it is given. A better title
  raises the odds; it is not a guarantee.
- "Build from the facts" uses the facts on the page, so a wrong fact
  (a cafe marked as a coworking space) gives a wrong line. Edit before
  Go, and fix the fact on the page.
- Forty changes are written per push run, with pauses that keep it
  inside Webflow's per-minute limit.
- A photo change takes six calls to Webflow (read the page, read its
  Images entry, write, publish the entry, publish the page, read the
  hosted links back), so photo changes go through more slowly than
  text.
- Photo thumbnails on the screen load straight from the pasted
  address. Some hosts refuse that, and the thumbnail then shows as a
  broken picture although the website copy is fine.
- Every Go asks GitHub to start the push. If the GitHub token in Vault
  is missing, changes wait for the schedule instead, which can be
  hours.

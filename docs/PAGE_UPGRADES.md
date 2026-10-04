# Page upgrades: improvements to listing pages, approved one by one

Control centre, Team tools menu, **Page upgrades** (or
`nomadmaps.io/?admin=upgrades`). Migrations 125 to 128.

## What it is

A queue of changes to the listing pages on nomadwise.io. Each card is
one change to one page: what the page says now, what is proposed, and
why the page is where it is in the queue. Nothing reaches the website
until a founder presses **Go**.

It exists because most pages are thin. On 4 Oct 2026, 246 of the 338
coworking pages had no description, 235 had no prices, and 1,008 of
the 1,011 live pages shared one generic search description.

## The order

Highest impact first. The score is built from:

- page views of that listing page in the last 90 days (most weight);
- how many Google reviews the place has;
- a quarter more for a coworking space than for a cafe;
- a description counts for more than a search description.

The reason is printed on every card, for example "151 page views in
90 days · coworking space · 202 Google reviews".

## Kinds

| Kind | What it changes | How it is made |
|---|---|---|
| Search description | The line Google shows under the title (Webflow: Meta Description) | Built in the database from the facts we hold. **Prepare more** adds the next 10 to 100 at once. |
| Page description | The text of the page (Webflow: More Info) | Written from the space's own website. **Ask for a batch** files a request; the batch is drafted in a Claude session and uploaded. |
| Photos | The five pictures of the page (Webflow: its Images entry) | Pasted by a founder, the way it is done for a new listing. See below. |
| Prices | Listed as a gap, with a request button | To be drafted the same way; not written to pages yet. |
| WiFi speed | Listed as a gap only | Comes from a nomad's test in the app or from the owner. |

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

- **Go**: approves the proposed text. The website push writes it and
  republishes the page within minutes. "Go for all shown" does the
  same for every card on the screen.
- **Edit**: change the words, then "Go with this wording".
- **Skip**: not this one. A skipped search description is not
  prepared again unless it is brought back from the Skipped tab. (A
  later drafted batch may offer a new description for a page whose
  earlier draft was skipped.)
- **Take back** (On its way tab): stops a change the push has not
  started writing. Once the push has claimed it, Take back is refused
  for a few minutes; use Undo on the Live tab after that.
- **Undo** (Live tab): the push puts back exactly what the page said
  before. That text is recorded when the push first claims the change,
  so a retry after a failed write cannot lose it.
- **Bring back** (Skipped tab): returns a skipped or undone card to
  the queue.

A change that the website refuses lands on the **Needs a look** tab
with the reason, and can be tried again.

## What it leaves alone

- A page with an owner keeps the description its owner wrote: drafted
  descriptions are not loaded for owned pages, and one approved before
  the page was claimed is refused at the last step. An Undo of a
  description is refused in the same way once the page has an owner.
- Price lines the sync wrote into More Info stay under a new
  description.
- One live change per page and kind at a time.
- No long dashes, and no HTML: a line starting `## ` is a heading,
  the rest are paragraphs.

## How a drafted batch gets in

1. A founder presses **Ask for a batch** (how many, and an optional
   note such as "London first"). The request is stored and shown on
   the card. It also appears in the nightly sync report on the
   `sync-reports` branch, under `upgrades.open_requests`.
2. In a Claude session the pages are read, the texts are written from
   each space's own website, and a migration is produced that calls
   `import_page_upgrades('[{"slug": ..., "kind": "description",
   "text": ..., "note": ...}]', '<batch name>')`.
3. Uploaded like any other change. The build applies the migration,
   the drafts appear under **Waiting for your Go**, and the request is
   closed.

Page views are refreshed the same way: a migration calling
`set_page_popularity()` with the latest 90 days.

## Where things live

| Thing | Where |
|---|---|
| Queue | `page_upgrades` (status: proposed, approved, applied, skipped, failed, undo_requested, undone, superseded) |
| Requests | `upgrade_requests` |
| Page views | `page_popularity` (slug, views, visitors, days) |
| Photos on each page | `venue_page_facts` (`photos`, `photo_urls`): seeded by migration 128, refreshed nightly from the Images collection, and updated straight after each photo write or undo |
| What each page holds | `venue_page_facts`, written nightly by `scripts/webflow_sync.py` (its own table, so the map's read of `venues` does not carry it) |
| Writing to Webflow | `scripts/webflow_sync.py`, "page upgrades" section, in the ten-minute push and the nightly run |
| Screen | `app/lib/screens/admin_upgrades_screen.dart` |

## Limits to know

- Page views come from PostHog and count nomadwise.io only, with bots
  left out. A page nobody visited scores on its Google reviews alone.
- The search description is built from the facts on the page, so a
  wrong fact (a cafe marked as a coworking space) gives a wrong line.
  Edit before Go, and fix the fact on the page.
- Forty changes are written per push run, with pauses that keep it
  inside Webflow's per-minute limit. A run that fills up asks for the
  next one straight away, so a larger "Go for all" finishes over a few
  runs.
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

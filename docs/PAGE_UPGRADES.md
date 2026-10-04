# Page upgrades: improvements to listing pages, approved one by one

Control centre, Team tools menu, **Page upgrades** (or
`nomadmaps.io/?admin=upgrades`). Migrations 125 and 126.

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
| Prices | Listed as a gap, with a request button | To be drafted the same way; not written to pages yet. |
| WiFi speed | Listed as a gap only | Comes from a nomad's test in the app or from the owner. |

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
| Queue | `page_upgrades` (status: proposed, approved, applied, skipped, failed, undo_requested, undone) |
| Requests | `upgrade_requests` |
| Page views | `page_popularity` (slug, views, visitors, days) |
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
- Every Go asks GitHub to start the push. If the GitHub token in Vault
  is missing, changes wait for the schedule instead, which can be
  hours.

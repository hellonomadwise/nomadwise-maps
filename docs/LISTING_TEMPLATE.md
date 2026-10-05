# The listing page template: changes made once, in Webflow

Kept apart from Page upgrades on purpose. Page upgrades changes the
words and photos of one page at a time, from the control centre. The
items here change how every listing page is built: its headings, its
structured data, its layout. Each is one change in the Webflow
Designer (the **Coworking Template** page) that reaches all 1,011
pages at once, so Jonathan works through them in Webflow himself.
Nothing here is written by the app.

Status: a first list, 4 Oct 2026. It is drawn from the page's
settings and the data behind it; nobody has yet gone through the live
page section by section for this list, so the layout items are
questions to check, not findings.

## What is known today

| Thing | How it is set now | Source |
|---|---|---|
| Page title | The template's SEO title is the item's **Title Tag** field, nothing else | Webflow page settings |
| Search description | The template's description is the item's **Meta Description** field | Webflow page settings |
| Sharing image | The first photo of the page's Images entry | Webflow page settings |
| Structured data | None set in the template's Schema markup setting | Webflow page settings, 4 Oct 2026 |
| Main heading | The **H1 Label** field, mostly "Name in Region - Area" (582 pages) or "Name in Region" (162) | CMS data |
| Titles in use | Around 200 different wordings; the commonest are "Name with WiFi in Region" (216), "Name Coworking Space in Region" (168), "Name: Cafe with WiFi in Region" (134) | CMS data |
| What the pages are found for | Almost always the place's own name: "alchemy uluwatu" (5,300 searches a month, position 7), "revolver canggu" (1,000, position 4), "flow workspace" (1,000, position 9) | Ahrefs, 4 Oct 2026 |

The last row matters most for this list. A listing page is found by
people who already know the place and are checking it: is it good to
work from, when is it open, how fast is the WiFi, where is it. The
pages that answer that fastest, above the fold and in a form Google
can read, are the ones that move up.

## The list

Each item says what to change, why, and how much work it is. Tick
them off here as they are done.

### 1. Structured data for every listing (highest value)

- [ ] Add a JSON-LD block to the template, filled from the item's
  fields: type (CafeOrCoffeeShop or CoworkingSpace), name, address
  parts, the map link, opening hours by day, the Google rating and
  number of reviews, the photos, the website.
- Why: it is how Google and AI assistants read the facts of a place
  without guessing from the layout. The template has none today.
- Work: one custom-code embed in the template, with the fields bound.
  The opening hours fields are free text, so they need a look first.
- To check before starting: whether an embed on the page already
  outputs some of this (the page setting is empty, an embed may not
  be), and Google's rule that a rating shown in structured data must
  also be visible on the page.

### 2. One main heading, and what it says

- [ ] Confirm each page has exactly one H1 and that it is the H1
  Label. (Ahrefs' crawl on 4 Oct flagged 22 pages on the site with
  more than one; which pages was not checked.)
- [ ] Decide the H1 pattern. "Name in Region - Area" reads oddly
  ("Hygge Kaffe in Avenidas Novas - Lisbon"). Since people search the
  name, the name alone as the H1 with the area as a line under it is
  cleaner and matches the search.
- Work: small, in the template. The H1 Label field also feeds the
  photo captions, so changing the pattern there changes those too.

### 3. The answers above the fold

- [ ] On a phone, check what is visible without scrolling: the name,
  whether it is open now, WiFi speed, the area, and the first photo
  should all be there before any filler.
- Why: these are the questions behind a name search.
- Work: layout, to be judged on the live page.

### 4. Links to nearby places

- [ ] A block of other listings in the same Location (or Region when
  the Location has few), under the main content.
- Why: it keeps a visitor on the site when this place is not the
  right one, and it gives every listing links from its neighbours,
  which is how Google finds and weighs them.
- Work: a collection list filtered by the same Location reference.
- To check: whether the template already has one.

### 5. A breadcrumb

- [ ] Country, Region, Location, then the place, as links at the top,
  with breadcrumb structured data.
- Why: Google shows the trail under the title in place of the raw
  address, and it ties each listing to its city page.
- Work: small; the references are already on the item.

### 6. Empty sections

- [ ] Sections with nothing to show (no description, no prices, no
  WiFi speed) should be hidden, not left as a heading over a blank.
- Why: 648 of the 1,011 pages have no description at all, so an empty
  block is the commonest thing on the template.
- Work: conditional visibility on each block.

### 7. Photos

- [ ] Check the photo alt texts come from the Images entry (they are
  written there: "Name", "Name 2", ...) and that the first photo is
  not lazy-loaded.
- Why: the first photo is usually the largest thing the page loads.

### 8. A way to claim the page

- [ ] On an unclaimed listing, a quiet line for the owner ("Is this
  your space? Claim this page") linking to the claim form with the
  place filled in.
- Why: the page is where owners first see their listing.
- To check: whether it is already there, and its wording against the
  owner-facing copy rules.

## What would make this list better

- Going through one live page on a phone and on a laptop, section by
  section, and adding what is seen to the items above.
- Ahrefs' site crawl, once the run that was in progress on 4 Oct has
  finished: it lists pages with long titles, more than one H1 and
  thin content by address.
- Search Console connected to the Ahrefs project, for real search
  figures per listing page.

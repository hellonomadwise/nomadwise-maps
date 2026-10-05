# Price check: the products on a listing page, kept true

Set up 5 Oct 2026 (migrations 131 and 132, `scripts/webflow_products.py`,
`app/lib/screens/admin_prices_screen.dart`).

## The rule

The bare minimum expected of Nomadwise is that a price on a listing is
the price on the space's own website. If a space ever questions a
price, the answer has to be "it is the one on your site" (Jonathan,
5 Oct 2026).

So a price is only ever taken from the space's own website (or its own
booking page): never another directory, a review, a blog, Google or
memory. It is written as their site shows it: same currency, same
unit, nothing converted, rounded or worked out from another price.

## What a "product" is

A coworking page on nomadwise.io lists what the space sells: a day
pass, a month pass, a meeting room by the hour, a private office. Each
is an item in the Webflow **Products** collection, in one of four
categories (Coworking, Meeting room, Private office, Other).

On 5 Oct 2026 there were 753 live products on 153 pages. 741 of them
had last been touched in May or August 2025, and none had been
compared with the space's website since.

Why the price matters more than it looks: the listing template's own
code reads the price off the page. The reservation request form quotes
it back to the visitor in the confirmation email, and the older card
payment code (still in the template) works its deposit out from that
same number. Nothing is stored separately, so correcting the price on
the page corrects it everywhere.

## Where it is

Control centre, **Team tools** (the nine dots, top right), **Price
check**. Or `nomadmaps.io/?admin=prices`. Founders only.

## How it goes, one space at a time

1. **Request a check.** On a space, press "Request a price check" (a
   note is optional). "Copy requests" puts the open requests on the
   clipboard: each space with its slug, our page, its own website, and
   the products our page shows now.
2. **The check.** In a session, each product is compared with the
   space's own website. What was found is loaded with
   `import_price_check()` in a migration (format below).
3. **What comes back.**
   - *The same*: stamped as checked, with the day and the page it was
     seen on. Nothing to press; nothing on the public page changes.
   - *Different*: the current price next to the one on their website,
     with what it was based on. Waits for a Go.
   - *Not found*: noted on the product. Nothing is proposed: not
     finding a price is not proof it ended.
   - *No longer offered*: a proposal to take the product off the page.
   - *New*: a proposal to add a product.
4. **Go, Edit, Skip.** Go puts that one change on the public page
   within minutes. Edit changes it first, then sends it. Skip leaves
   the page as it is (and "Bring the skipped change back" undoes the
   skip). **Undo** on an applied change puts the old one back.

A founder can also correct a product, add one or take one off at any
time ("Correct it", "Add a product", "Take it off the page"). Saving
is the Go.

Until a space is checked, its prices stay on the page exactly as they
are.

## What Go does on the website

The ten-minute website push (`webflow_push.yml`, step "Products and
prices") runs `scripts/webflow_products.py`:

- **Update**: writes only what the change changes (the price and its
  label, or the name, the details, the category). Anything edited by
  hand in Webflow since is left alone. A live product is republished.
- **Take off**: the item is unpublished and archived. It is kept in
  Webflow, so Undo can put it back.
- **Add**: a new item, with the page's settings (currency, country,
  photo, commission) copied from one of the page's other products. A
  page with no products at all cannot get its first one this way; add
  that one in Webflow.

Before it writes, the push claims the change; from then until it
reports back, "Take it back" and a second edit are refused ("it is
being written right now"), so the page and our copy cannot part ways.
If the report back fails, the change is never marked as failed (the
page has been changed); the next run repeats it, which changes nothing
more, and records it then.

A change that could not be written shows as "Needs a look" with the
reason, and "Go again".

## Our copy

`venue_products` holds a copy of every product, with:

- `site_updated_at`: when it was last changed on the website;
- `checked_at`, `checked_url`: the last time it was confirmed against
  the space's own website, and the page it was seen on;
- `check_result`: `same`, `changed` (corrected to match), `differs`
  (their site shows something else and the page was left as it is) or
  `not_found`.

About once a day the push copies the whole Products collection into
it (`set_venue_products`), so a product edited, added or archived by
hand in Webflow is seen here too. A name or price changed by hand
since its last check no longer counts as checked. A read from Webflow
that comes back short is refused rather than taken for removals.

The first load (migration 132) came from the Webflow export of
5 Oct 2026.

## Things to know

- **"Starting from" price.** One product per page carries the price
  that shows as "starting from" on mobile (the Webflow switch
  "Starting from"). It is shown as a chip. Which product carries it is
  chosen in Webflow; a new product never takes it over, and taking
  that product off the page leaves the page without a starting price.
- **Nomadwise discounts.** A few products (SOKKOOL) show an original
  price and a saving beside the discounted price. A new price here
  replaces the discounted price only; the other two are changed in
  Webflow.
- **Affiliate products** keep their link; only the fields a change
  names are written.
- **A page with an owner.** For now anything changed here still goes
  on the page. The Owner account will get its own product list next,
  starting from these products.
- **Currencies.** A new currency has to exist in the Webflow
  Currencies collection first; the change fails with that reason
  otherwise.

## Loading a check

A migration (next free number in `supabase/`) with one entry per
space:

```sql
select public.import_price_check($check$[
  {"slug": "germany-hamburg-4-walls-coworking",
   "url": "https://their-site.example/prices",
   "checked_on": "2026-10-05",
   "summary": "One or two sentences on what their prices page shows.",
   "items": [
     {"ref": "Day Pass", "result": "same"},
     {"ref": "Week Pass", "result": "changed", "amount": 95,
      "note": "Shown as 95 € per week on the prices page"},
     {"ref": "Night Pass", "result": "not_found",
      "note": "Not on their prices page"},
     {"ref": "Old Pass", "result": "gone",
      "note": "Their site says it ended in June"},
     {"result": "new", "name": "Evening Pass", "category": "coworking",
      "amount": 12, "currency": "EUR",
      "details": ["From 6 pm", "Weekdays"],
      "note": "Listed under Passes"}
   ]}
]$check$::jsonb, 'name of this load');
```

- `ref` is the product's name as our page has it (exact, any case),
  or the short id in square brackets from "Copy requests".
- A `changed` item names only what changes: `amount`, `name`,
  `details`, `category`, `currency`, and `label` when the price has to
  be written out by hand ("£40 + VAT"). Otherwise the label is written
  from the amount: "€25", "£1,085", "100,000 IDR".
- `amount` is a number. Text is read only when it can mean one thing
  ("1500", "12.50", "1,500"); "12,50" is refused.
- Every `note` says where on their site it was seen. It shows on the
  card as "Based on", with the `url` and the day.
- The result (what was loaded, what was left out and why) is not
  visible from a session. The space's page in Price check shows the
  counts of the last check.

Left out, with a reason: a name that matches no product or more than
one; a product no longer on the page; a product with a change already
on its way to the page; a new product whose name is already on the
page.

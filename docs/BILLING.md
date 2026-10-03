# Plan & billing: owners run their own plan

The Owner account's "Plan & billing" tab lets an owner, without
writing to us:

- see their plan (Free or Verified), its status, the next payment and
  the card on file;
- view and download every invoice and receipt;
- switch down to Free (their renewal is turned off; they stay Verified
  until the end of the year they paid for), with an optional reason,
  and switch back ("Keep Verified") before it ends;
- update their card, and their billing name, address and tax ID, on
  Stripe's secure page, opened straight at the right step (no second
  sign-in), which then brings them back to the tab.

Everything is read live from Stripe (migration 107). Each switch is
logged (owner_billing_events) and emails hello@nomadwise.io with the
reason, so we can help. Card details never touch our servers.

## Switching it on (Jonathan, once, about 10 minutes)

Until step 3 is done the tab shows the plan from our own records and
says billing tools are being switched on; nothing breaks.

1. **Stripe customer portal.** Stripe: Settings, Billing, Customer
   portal. Turn on: Invoice history; Payment methods (update);
   Customer information (name, billing address, tax ID). Leave
   "Cancel subscriptions" off: owners switch to Free in the Plan &
   billing tab instead, which keeps them Verified to the end of the
   paid year, asks for a reason and tells us. Under Business
   information add the Nomadwise logo and colours (#FF444F). Set the
   default redirect link to https://nomadmaps.io/?owner&billing.
   Save.
2. **A restricted key for billing.** Stripe: Developers, API keys,
   Create restricted key. Name it "Nomad Maps billing". Permissions:
   Customers Read; Invoices Read; Payment Methods Read; Subscriptions
   Write; Customer portal Write. Everything else None. Create it and
   copy the key (starts rk_live_).
3. **Into the Vault.** Supabase: Project, Integrations (or Database),
   Vault, Add new secret. Name `stripe_billing_key`, value the key.
   Save. (Paste it yourself; it is never written anywhere else.)
4. Check: open a Verified space's Owner account (control centre,
   "Their Owner account") and the Plan & billing tab: the card and
   invoices appear.

## Prices by region (Jonathan, once, about 30 minutes)

Decided 1 Oct 2026 (Leonie): Verified is priced by the space's
country, monthly or yearly, in the country's currency. Four groups:

| Group | EUR | GBP | USD | AUD (Australia only) |
| --- | --- | --- | --- | --- |
| A. High cost | 15 / 149 | 13 / 129 | 17 / 169 | 25 / 249 |
| B. Europe | 10 / 99 | 9 / 89 | 11 / 109 | 17 / 169 |
| C. Middle | 6 / 59 | 5 / 49 | 7 / 69 | 10 / 99 |
| D. Lower cost | 4 / 39 | 3.50 / 35 | 4.50 / 45 | 6.50 / 65 |

(monthly / yearly). The prices live in Stripe; the app reads them.
Until the steps below are done, everyone still sees and pays 99 EUR a
year through today's payment link, so nothing changes by itself.

1. **The two keys need more permissions.** Stripe: Developers, API
   keys. Edit "Nomad Maps billing" (the Vault key, rk_live_): add
   Checkout Sessions **Write** and Prices **Read**. Edit the GitHub
   key (the one in the STRIPE_API_KEY secret): add Prices **Read**.
   Save both. (No new keys to paste anywhere.)
2. **Eight prices on the Verified product.** Stripe: Product catalog,
   open "Verified listing on nomadwise.io" (or create it). For each
   group, add two prices: Recurring, Monthly, EUR amount from the
   table; and Recurring, Yearly, EUR amount. On each price, under
   "Add another currency", add GBP and USD with the amounts from the
   table (and AUD on group A). Give each price a lookup key or
   description like "Verified A monthly" so they are easy to tell
   apart. Copy each price id (starts price_).
3. **Into the control centre.** Nomad Maps, control centre, team tools
   menu, Pricing. Tap each group and paste its monthly and yearly
   price ids. Save. Within the hour the hourly Stripe check reads the
   amounts in every currency and the group shows "In Stripe"; from
   then on the claim form shows that group's prices for its countries
   and takes owners to Stripe Checkout in the currency they chose.
4. **Check:** open the claim page for a space in Thailand
   (nomadmaps.io/?claim=<its name>): step 3 shows USD with a toggle to
   EUR and GBP, monthly or yearly. A UK space shows pounds only.
5. **Promotion codes** keep working: Checkout has the code box. No
   founding-price offer for now (Jonathan): normal prices first, see
   how sales go. Stripe keeps each subscriber on the price they signed
   up at anyway, so a later price change never touches existing
   owners.

The country groups and each country's currency are editable on the
Pricing page (tap a country). A country name the database does not
recognise is listed there with a "Map" button; until mapped, its
spaces are priced as group B. A space with no country at all gets one
from the site's own places, Google's address or the nearest Region
(migration 119, on the way in and nightly); the Pricing page counts
any still without. Before a space is chosen on the claim
form (so no country is known yet) the overview says "from €4 a
month", the cheapest group, rather than group B's price (migration
118). The Webflow copy on the Get listed page says "from €4 a month"
too (docs/GET_LISTED_PAGE_REPLACE.md).

## Later: monthly as well as yearly

When a monthly Verified price exists in Stripe, add it to the
customer portal's "Subscriptions, switch plans" list and owners can
move between monthly and yearly themselves from "Billing name,
address and tax ID" (the portal home). The tab then shows the price
and interval of whichever plan they are on.

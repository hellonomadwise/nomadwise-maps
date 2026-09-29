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
   Customer information (name, billing address, tax ID); Cancel
   subscriptions, "At the end of the billing period". Under Business
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

## Later: monthly as well as yearly

When a monthly Verified price exists in Stripe, add it to the
customer portal's "Subscriptions, switch plans" list and owners can
move between monthly and yearly themselves from "Billing name,
address and tax ID" (the portal home). The tab then shows the price
and interval of whichever plan they are on.

# Claiming a listing

How a coworking space or cafe becomes a paying Verified listing, and
what Jonathan has to do about it.

## The two ways money arrives

**1. Jonathan sends the link.** Someone emails asking to be listed. He
finds them in the control centre, opens **Listing plan**, taps **Copy
payment link**. That link carries the space's id, so when they pay the
plan is set automatically. Nothing to match, nothing to type.

**2. The owner comes on their own.** They land on
`nomadmaps.io/?claim`, search for their space, say who they are, and
pay. The claim is written to the database *before* they reach Stripe,
and the payment link carries the claim's id. Same result: the payment
always knows whose it is.

A payment that carries neither — someone who found the bare Stripe
link and paid — still lands safely as a **Paid, needs matching** card
in the control centre. The Stripe custom fields below make even that
case name itself.

## What the owner sees

Three steps, no account, no password.

1. **Find your space.** A search of the directory. Each result says
   whether it already has a page on nomadwise.io. If their space is not
   there, *"My space isn't here — add it"* searches Google Maps
   instead, which gives us the real place id, address and coordinates —
   so photos, opening hours and the rating fill themselves in.
2. **About you.** Name, role, email, phone, and where booking requests
   should go. Plus a free-text box for anything we should know.
3. **Your Verified listing.** What they get, €99 a year, and a button
   to Stripe.

After paying, Stripe returns them to `nomadmaps.io/?claimed`, which
says the page is being set up today and that an email with a private
link for photos and prices follows.

## What happens in the database

`listing_claims` holds the claim. Nothing an unpaid stranger types ever
reaches the `venues` table — a brand-new space only becomes a venue row
once the money has landed.

When `scripts/stripe_sync.py` sees the payment (hourly, and at the end
of every website push) it calls `claim_paid()`, which:

- finds the space, or creates it from the Google Places details;
- sets `listing_tier = 'verified'` with the owner's name, email and
  enquiry address, and the dates from the Stripe subscription;
- asks the website sync to rewrite the page;
- puts a brand-new space into the queue as `website_status = 'queued'`;
- pings the phone: *"PAID — new space, publish today"* or *"PAID —
  Verified listing"*.

It is safe to run twice: a claim already settled is re-answered with
the same space and no second ping.

## Jonathan's job, per sale

For a space **already on the site**: nothing. The badge, the owner's
details and the booking-request button go on at the next push, within
about ten minutes.

For a space **not on the site yet**: the phone pings, the space is
waiting in the queue with its Google details already filled in. Review
it the way any queued space is reviewed — check the photos, the region,
the slug — and approve. That is the whole job, and it is why the promise
is same-day rather than three days.

A claim that never pays sits as `status = 'started'`. Those are warm
leads: someone wanted this enough to fill in the form. A phone ping
(*"Claim started"*) says when one appears.

## The Stripe settings this needs

Two things in the Stripe dashboard, on the **live** payment link:

**Custom fields** (Payment links → the Verified link → edit). Add two
text fields:

- *Name of your space* — key `name`
- *Link to your page on nomadwise.io (if you have one)* — key `link`,
  optional

`stripe_sync.py` reads both. The second one is a second safety net: if
someone pays without coming through the claim form, a nomadwise.io
address typed here matches the space by its slug.

**After payment** (same edit screen). Set *Don't show confirmation
page* → redirect to:

```
https://nomadmaps.io/?claimed=1
```

so nobody is left on Stripe's generic page wondering whether anything
reached us.

## Where the links go

- The **Get listed** page on nomadwise.io points at
  `https://nomadmaps.io/?claim`.
- Every free listing page can carry a quiet line — *"Own this space?
  Claim your listing"* — linking to
  `https://nomadmaps.io/?claim=` + the space's name, so the search box
  arrives already filled in.
- The control centre's Listing plan page keeps its own **Copy payment
  link** button for spaces Jonathan sells to directly.

## Not built yet

The **private owner page** for photos, description, prices and hours —
the "details after" half of the promise. The plan is a long secret in
the address rather than a password, emailed after payment, with
whatever the owner submits going through the same review as everything
else. Until it exists, the details come by email and Jonathan puts them
in through the control centre.

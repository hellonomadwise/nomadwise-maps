# Claim journeys: what each visitor did on the claim page

Built 27 September 2026, the morning of the first outside click on
the claim page from the Get listed page.

## Where to look

Control centre, Paid listings tab, first card **Claim journeys**
(also a button at the top of the Analytics screen). One card per
opening of nomadmaps.io/?claim in the last 7, 30 or 90 days, newest
first, team devices left out:

- when, phone or desktop, how long they stayed, "came back" when
  the same device has opened the page before
- where they arrived from (the nomadwise.io page, another site, or
  direct) and what was already in the search box
- a four-part bar for how far they got: Find, Space chosen, Owner
  details, Free or Verified
- how it ended: went to Stripe, claimed free, left on such a step
  after so long, or still on the page

Tap a card and the whole visit reads in order, with the seconds since
the page opened: searched "instant crush", 3 results; chose Instant
Crush, a page already on nomadwise.io; typed their name; typed their
email; left the page on the owner details step after 1m 10s, having typed their
name and email.

The strip at the top counts how many visits reached each step, which
is the funnel in one line.

## How it is recorded

The claim page records these events about itself, each with a visit
id (one per opening), the step it happened on and the seconds since
opening. They land in `app_events` (the same table the Analytics
screen reads) and in PostHog, project 99075, with `app:
nomadwise-maps`:

| Event | When |
|---|---|
| `claim_opened` | the page opens (seed, from, referrer, device) |
| `claim_searched` | a search ran (query, result count) |
| `claim_place_searched` | a Google Maps search ran on Add your space |
| `claim_step` | the step changed (`to`, `how`: picked_listed, picked_unpublished, link_matched, google_place, not_here, back, continue) |
| `claim_typed` | first text in a field (name, email, phone...), once per field |
| `claim_blocked` | Continue pressed without a name or email |
| `claim_already_verified` | tapped a space that is already Verified |
| `claim_to_payment` | chose Verified, sent to Stripe |
| `claim_free` | claimed free |
| `claim_failed` | the claim could not be saved (why) |
| `claim_left` | closed the tab or went elsewhere (step, seconds, fields typed) |

`claim_left` is sent as the page is being closed, with a request the
browser keeps alive after the page is gone. It is best effort: a
phone that kills the tab from the app switcher may not send it, in
which case the card says "stopped on X, no leave recorded" and the
last event is still there.

What is typed into the fields is not recorded, only that the field
was filled; the actual name and email only reach us when they press
Claim for free or Go Verified, as a claim.

Ghost mode still applies: a browser opened once at nomadmaps.io/#internal
records nothing.

## PostHog

Dashboard **Claim page: journeys** (project 99075):
https://eu.posthog.com/project/99075/dashboard/977896

Four tiles, all last 90 days: the funnel (opened, chose a space,
reached Free or Verified, finished by Stripe or free claim); visits
and finishes per day; where visitors leave (the step, and average
seconds on the page); where visitors come from (the nomadwise.io page
or outside site, with how many of those visits reached Owner details and
finished). The tiles fill from the first build that carries the
events; before that they show nothing or only the old claim_opened
rows.

The in-app view is the one to read for a single visitor; PostHog for
the shape over months.

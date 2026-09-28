# The paid path, tested: a listing pays and becomes Verified

28 September 2026. Only the payment path: claim, pay, payment
matched, approved, recorded as Verified, owner told at each step,
and cancelling. What a Verified listing gets on the page (badge,
placement, requests, Owner account) is the next step and is not
tested here. About 25 minutes.

## Before you start (10 min)

1. Upload stripe_sync.zip (the sync now accepts a zero-amount
   checkout as paid) and wait for the green build.
2. Stripe: Products, Coupons, New: 100% off, duration Once, name
   TESTVERIFIED. Then Promotion codes, New: code TESTVERIFIED on that
   coupon. Then the Verified payment link, edit, turn on "Allow
   promotion codes". Save.
3. Pick a real free page on the site with no owner yet, one you are
   happy to set back to Free afterwards.
4. A spare email address that is not a team account (any Gmail).
5. Open the control centre on the laptop, Owners tab; the phone for
   pings; the spare inbox.

## As the owner (8 min)

| Step | Do | Expect |
|---|---|---|
| 1 | Private window, nomadwise.io Get listed page, Claim your space | The claim form, Find your space |
| 2 | Search the page's name, tap it | Owner details, the space named at the top |
| 3 | Your name, the spare email, a phone number, Continue | Free or Verified |
| 4 | Go Verified | Stripe checkout with the email prefilled |
| 5 | Add promotion code TESTVERIFIED, complete | Total 0; back on nomadmaps.io: "You are Verified" with the Owner account button |
| 6 | Spare inbox | Nothing yet; "Payment received" comes once the sync has seen the payment |

## As us (8 min)

| Step | Do | Expect |
|---|---|---|
| 7 | GitHub, Actions, "Stripe plans (hourly)", Run workflow | Within a minute: phone ping about a Verified payment; spare inbox gets "Payment received for X" (house style, Owner account button) |
| 8 | Owners tab, Waiting for your decision | The card: PAID, APPROVE?, name, email, phone, the ownership line, Google and Map links |
| 9 | Approve, make it Verified | Card gone from the waiting list; spare inbox gets "X is Verified on nomadwise.io" |
| 10 | Owners tab, Verified listings | The space is there: VERIFIED, owner name and email, "Renews" a year from today |
| 11 | Emails to owners | Rows for payment_received and approved_verified, "Postmark accepted it" |

## Cancelling (5 min)

| Step | Do | Expect |
|---|---|---|
| 12 | Stripe dashboard, Customers, the spare email, cancel the subscription immediately | |
| 13 | Run "Stripe plans (hourly)" again | Owners card for the space shows lapsed / back to Free |
| 14 | Listing plan on the space | Set it to Free if it is not already; the test leaves nothing behind |

## Afterwards

- Claim journeys: mark your visit "This was me".
- Tell me which "expect" lines did not hold, with a screenshot each.

## Next steps after this passes

The five things a Verified page gets, one at a time, each tested the
same way: the badge and placement (Webflow), the Owner account
(edit, review, on the page), booking requests to the inbox, the
message in the advert slot, and billing management (Stripe portal).

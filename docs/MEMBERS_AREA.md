# Nomadwise For Spaces: the members area

Naming rule (Leonie, 21 Sep): "members area" is internal shorthand only.
Anything an owner sees says **Owner account** and **Manage my listing**,
never "members area", so nobody mistakes it for sign-in software for
their own members, which other platforms sell.

A reaction to the concept mockups (owner journey and members area, 21 Sep
2026), and where the work sits in the queue.

## What the mockups propose

An owner workspace branded **Nomadwise For Spaces**, with five sections:
Overview, My listing, Performance, Nomad perks, Membership. The journey
into it starts from a "For space owners" page on nomadwise.io, goes
through search and claim, then an account (email link), then an
ownership check, then payment, then profile editing.

The listing page itself gains a before and after: the same page, but the
sidebar advert slot is replaced by the owner's own event or offer.

## What is genuinely good in it

**The name.** "Nomadwise For Spaces" solves the branding problem on its
own. The owner never needs to hear the word Nomadmaps. Nomad Maps stays
what it is, the nomad-facing map and the founders' control centre, and
the owner-facing surface carries the brand that owns the traffic.

**Replacing the advert with the owner's promotion.** This is the
strongest idea in the concept and it is not one we had. A Verified page
that shows the space's own event, offer or announcement where an
affiliate advert used to be is a benefit an owner can see, point at and
show their team. It is far more concrete than a badge.

The obvious objection, that we give up the advert income, does not hold.
A listing page sees 15 to 40 views a month and that slot earns on
impressions, so it is worth well under a euro a year per page, against
99 EUR for the membership. The slot only disappears from pages that have
paid; the thousand free listings keep theirs. The ratio is something
like a hundred to one, so this is among the cheapest things we can give
away and it belongs on the pricing page as a headline benefit, not as a
later phase.

Two caveats. Verified should never promise an ad-free page, only that
one slot, which the concept was careful about. And an owner's promotion
goes through the same review as their description before it publishes.

**Nomad perks.** A discount or welcome offer the owner posts, shown to
nomads. Costs us nothing, gives the owner something to do in the members
area between renewals, and gives nomads a reason to use the directory
rather than Google. Good retention mechanic on both sides.

**Performance in the app rather than a quarterly email.** Better. An
owner who logs in to see their numbers is an owner who renews. The
quarterly email becomes the prompt to log in, not the product.

## Where I would push back

**Accounts and ownership checks before payment.** The concept puts
account creation and an ownership review in front of the card. We
deliberately went the other way: pay first, details after, no password.
Two reasons. A long form in front of the card loses people who would
have paid. And an ownership review queue is manual work for Jonathan on
every single sale, which is the opposite of the "boring review work"
target.

Paying with a card is itself reasonable evidence of ownership, and it is
reversible: if a claim turns out to be wrong, refund it. The concept's
own "This profile already has a manager" screen is the case that does
need a check, and that is rare.

**Decided (21 Sep 2026): pay first stands.** An unclaimed space is
claimed and paid for in one go, with no account and no review. A check
is required only where a space is already claimed, or where something
looks wrong. Sign-in arrives later as a convenience for managing an
existing membership, never as a gate in front of the card.

**The numbers in the brief are unverified.** The concept cites about
2,400 listing page visitors in 30 days and 15 to 40 per listing, and says
plainly that these were supplied rather than checked. Worth confirming in
PostHog and Search Console before either figure goes in front of anyone.

## The Webflow constraint, and the way round it

Webflow cannot give third parties logins, private dashboards or the
ability to edit their own content. That is a real limit and it is not
worth fighting.

The split that works, and that the existing pipeline already implements:

- **Webflow stays the public surface.** It is what Google indexes and
  what earns the traffic. Nothing about that changes.
- **Everything behind a login lives in the app.** The members area, the
  editor, the analytics, the billing.
- **Owner edits flow back through the existing sync.** An owner changes
  their description in the members area, it is stored, Jonathan approves
  it, and the push run writes it into the Webflow CMS and republishes,
  which is exactly what happens today for every other field. The
  concept's "publish approved changes" step is already built.

The advert replacement is the same Designer pattern as the Verified
badge: a conditional block bound to CMS fields (promotion title, image,
link, call to action). If the Verified switch is on and a promotion
exists, show it; otherwise show the default advert.

One obstacle: the Coworking collection is at Webflow's **60 field limit**.
Four new promotion fields means renaming four unused ones again, or
finally merging the Images collection into the listing. The second is the
better answer and also buys headroom against the 20,000 item ceiling.

## The domain question

Nomad Maps lives at nomadmaps.io. An owner-facing members area should
not. Options, cheapest first:

1. **`spaces.nomadwise.io`** pointing at the same app, with the claim and
   members routes served there. A DNS record and a hosting change. The
   catch: GitHub Pages serves one custom domain per repository, so
   serving both nomadmaps.io and a nomadwise.io subdomain means either
   moving the hosting to somewhere that allows several (Cloudflare Pages
   is free and does) or putting a proxy in front. Neither is a big job.
2. **`nomadwise.io/spaces`** as a path on the main domain. Cleaner for an
   owner, better for trust, but Webflow holds the apex, so it needs a
   reverse proxy (a Cloudflare Worker) in front of the whole site.
   Realistic, but a bigger change and a new thing that can break.
3. **Rename Nomad Maps outright.** Not worth it. The nomad-facing map is
   a different product with a different audience, and the name works for
   it.

Recommendation: option 1 now, option 2 only if owners tell us the domain
bothered them.

## Where this sits in the queue

Nothing here changes the order of what is already in flight. The members
area is worth nothing until someone has paid, and nobody can pay until
the Webflow work and email sending are done.

**Now, before the first sale**
1. Webflow: Verified badge, paid listings sorted first, booking button
   repointed
2. Email sending (Resend account and DNS)
3. Repoint the "Is this your business?" link on the listing template to
   the claim flow

**Next, to serve the first customers**
4. The private owner page: photos, description, prices and hours after
   payment. A long secret in the address, no password. This is the first
   slice of the members area and it is the piece a paying owner actually
   needs.
5. Owner promotions replacing the advert slot. Cheap to give, easy to
   show, and the clearest thing on the pricing page, so it belongs with
   the first paying customers rather than in a later phase. Needs the
   Webflow conditional and the CMS fields, which is the same Designer
   session as the badge.
6. Automatic replies to booking requests, including the approach to the
   unclaimed space's owner

**Then, the members area proper**
7. Move the private page behind a proper sign-in and add Overview and
   Membership
8. Performance: views, sources and outbound clicks from PostHog and
   Search Console
9. Nomad perks
10. `spaces.nomadwise.io` and the Nomadwise For Spaces branding, best
    done at the same time as step 7 so owners only ever see one address

**Open questions to settle before step 7**
- Which advert slots can an owner replace (the sidebar one is settled;
  anything above the fold is a separate decision)
- How do multiple locations under one owner work
- How much ownership review do we actually want, given pay first
- Is the pilot 5 to 10 spaces, and which ones

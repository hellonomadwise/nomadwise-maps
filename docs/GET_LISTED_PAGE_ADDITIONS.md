# Get listed page: additions for the free claim and the Owner account

Page: `/list-my-coworking-space-on-nomadwise` in the Webflow Designer,
plus the site header and footer. This is on top of
GET_LISTED_PAGE_REPLACE.md; do that one first if it is not done, then
this. Same rules: styling stays, only words and links change. Every
claim button links to `https://nomadmaps.io/?claim`, new tab (keep the
`?claim` spelling in Webflow: the footer snippet recognises it and
records which page sent the visitor). The sign-in address people are
given is `https://nomadmaps.io/owner`.

What changed since the first document: a space can now claim its page
for free, not only Verified, and every owner (free or Verified) gets
an Owner account at nomadmaps.io/owner to edit their page. The page
needs to say both.

---

## A. Site header (Navbar, on every page)

Add two links at the right end of the menu, after the existing ones.
The Navbar is usually a component, so one edit covers the whole site.
Check the mobile menu shows them too.

**Link 1.** Text: For space owners
Link: this page, `/list-my-coworking-space-on-nomadwise`, same tab.

**Link 2.** Text: Owner sign in
Link: `https://nomadmaps.io/owner`, new tab. If the Navbar has a
button style (like the red one), use it for this link so it stands
apart from the menu text.

---

## B. Hero (section 1 of the first document)

**Button 1.** Was: Claim your space. Keep the label and link.

**Button 2.** Was: Contact Us with a mailto link. Replace this:
Contact Us
With this:
Owner sign in, link `https://nomadmaps.io/owner`, new tab.
(hello@nomadwise.io is in the footer and the FAQ; the hero button is
better spent on owners who already have a page.)

**Line under the buttons.** Add a small line of text if the layout has
room:
Listing is free and stays free. Verified is 99 EUR a year, cancel any
time.

---

## C. Section "Two ways to be on nomadwise.io" (section 4 of the first document)

**Subheading.** Add under the heading, or as the first line of the
section:
Both start with the same two-minute claim. Choose at the end.

**Item 1, Free.** Replace this:
Free
A page built from public information, with a Contact the space button
that sends nomads to your website or map listing. Free listings are
added as we get to them, and you can correct the facts on your page
at any time.
With this:
Free
A page with a Contact the space button that sends nomads to your
website or map listing. Claim it and you get an Owner account to
correct the facts and add your own description, prices, opening hours
and photos. Every change is read by a person before it goes on the
page. New spaces are added as we get to them.
Button: Claim for free, link `https://nomadmaps.io/?claim`, new tab.

**Item 2, Verified.** Keep the text from the first document. Add:
Button: Go Verified, link `https://nomadmaps.io/?claim`, new tab.
Small line under the button:
Billed once a year through Stripe. Cancel any time; the listing stays,
back on the free plan.

**Item 3, How it works.** Replace this:
How it works
Find your space on the claim form, or add it from Google Maps if it
is not on our map yet. Tell us who you are and where booking requests
should go. Pay through Stripe. Three steps, no account to create.
Billed once a year. Cancel any time.
With this:
Simple from the first step
1. Find your space. Search our map, or add it from Google Maps if it
   is not there yet. No duplicates, no account to create.
2. Tell us who you are. Your name, your email, where booking requests
   should go. We check the claim before anything changes on the page.
3. Free, or Verified. Claim for free, or pay 99 EUR through Stripe.
   Then sign in to your Owner account and make the page yours.

If the layout lets you, the Free and Verified items look best as two
cards side by side with the three steps as a strip underneath, the
way nomadmaps.io/spaces shows it. If not, three items in a row is
fine.

---

## D. FAQ (section 6 of the first document)

**Q1.** Replace the last two sentences:
We ask you for your photos, description and prices then, so
nothing holds the page up while you gather them.
With this:
Choose Free or Verified at the end. Either way you get an Owner
account to add your photos, description and prices whenever you are
ready, so nothing holds the page up while you gather them.

**Q4.** Replace this:
How can I update the information on my page?
Email the new details to hello@nomadwise.io and we put them on after a
quick check. Every change is read by a person before it goes live, on
every plan, which is what keeps the pages trusted.
With this:
How can I update the information on my page?
Sign in at nomadmaps.io/owner with the email you claimed with, change
what you like and submit. We read every change before it goes live,
on every plan, which is what keeps the pages trusted. Not claimed
yet? Claim your page first; it is free.
(Make "nomadmaps.io/owner" a link to https://nomadmaps.io/owner, new
tab, and "Claim your page" a link to https://nomadmaps.io/?claim.)

**New question, add after Q4:**
I claimed for free. Can I go Verified later?
Yes. Sign in to your Owner account and press Go Verified, or open the
claim form again with the same email. Your page and everything you
added stay as they are; the badge, the booking button and the place
above free listings come on once the payment is in.

---

## E. Bottom call to action (section 7 of the first document)

Under the founders' note there is one button, Claim your space. Add a
second, plain-style button next to it:
Owner sign in, link `https://nomadmaps.io/owner`, new tab.

---

## F. Footer (section 8 of the first document)

Add two links to the footer column that holds the site links:
For space owners, link `/list-my-coworking-space-on-nomadwise`
Owner sign in, link `https://nomadmaps.io/owner`, new tab

---

## G. Nothing to do, for the record

- The listing pages' "Is this your business?" link keeps pointing at
  `https://nomadmaps.io/?claim`; the footer snippet adds the space.
- nomadmaps.io/spaces is a page in the app, not in Webflow. The app's
  menu links to it ("Own a space?"), and it links back to this page
  under "How it works" and to nomadmaps.io/owner under "Owner sign
  in". Nothing to set up in Webflow for it.

## Words that must not appear anywhere on the page when you are done

booking engine, commission, deposit, instant booking, on request,
within 24 hours, featured badge, members area, page views, reports,
analytics, perks. Search the page for each before publishing.

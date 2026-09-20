# Verified listings: the Designer steps

One-off setup in Webflow so a Verified listing shows its badge, sits
first in its city and area, and offers a Request a booking button.
The fields already exist on the Coworking collection (renamed from the
old booking engine, since the collection is at Webflow's 60-field
limit); Nomad Maps fills them, so nothing here needs typing per
listing.

| Field (Designer name) | Field slug | Nomad Maps writes |
| --- | --- | --- |
| Verified (switch) | premium-member | on for Verified, off for free |
| Enquiries On (switch) | booking-engine | on for Verified, off for free |
| Listing Rank (text) | booking-model | "1" for Verified, "0" for free |
| Enquiry Email (email) | coworking-space-email-3 | the owner's address, else hello@nomadwise.io |

## 1. The badge on the listing page

Open the Coworking template page. If a "Premium" badge element from
the old set-up is still there, rename its text to "Verified" and keep
its condition; otherwise add a small element (an icon and the word
Verified) near the listing name and give it conditional visibility:
show when Verified is On.

The same badge can go on the listing cards inside the city and area
pages (the collection lists on the Region and Location templates):
add it to the card and set the same condition.

## 2. Verified first in city and area lists

On the Region template and the Location template, select the
collection list of listings, open its settings, and add a sort:
Listing Rank, Z to A. Keep whatever sort you had as the second rule
(rating, name), so Verified listings come first and the rest keep
their old order. Because the field is text, "1" sorts above "0".

## 3. The Request a booking button

On the Coworking template, add a button labelled "Request a booking"
where you want it (near the website and WhatsApp links is natural).
Conditional visibility: show when Enquiries On is On. Give the button
an ID of `enquire` (element settings, ID field).

Set its link to `https://nomadmaps.io/?enquire=` for now. Then add
this to the page's custom code, before the closing body tag, so the
button carries the listing's own slug:

```html
<script>
  (function () {
    var b = document.getElementById('enquire');
    if (!b) return;
    var slug = location.pathname.split('/').filter(Boolean).pop();
    b.href = 'https://nomadmaps.io/?enquire=' + slug;
  })();
</script>
```

The form lives on Nomad Maps: the nomad fills in name, email, what
they want, dates and a note, and the request is emailed to the
listing's Enquiry Email with a copy to hello@nomadwise.io. Nomad Maps
switches Enquiries On for every Verified listing.

## 4. The enquiry email

Nothing to place. The field is read by the booking requests build to
know where a request goes; it is never shown on the page.

## 5. Publish

Publish the site once after these changes. From then on, saving a
Listing plan in Nomad Maps updates the listing's fields and
republishes that item on its own.

## The five legacy premium pages

Lisbon-Cowork, SOKKOOL, ALTER SPACE Siargao, Ofis Voyvoda Istanbul
and Monday still have the old Premium switch on, so they will show
the Verified badge as soon as step 1 is done. They appear in the
control centre's Paid listings section flagged as "no plan here";
give each a plan (Verified with the dates, or Free) and the page
follows within minutes.

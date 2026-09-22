# Verified listings: the Designer steps

One-off setup in Webflow so a Verified listing shows its badge, sits
above every free listing in its city and area, and offers a Request a
booking button.
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

## 2. Verified above free listings, rotating, then WiFi for the rest

On the Region template and the Location template, the collection
list of listings sorts by, in this order:

1. **Listing Rank, Z to A** (replaces the older "Verified, Is On
   First" rule; delete that one)
2. WiFi Rating, largest to smallest
3. Google Reviews, largest to smallest

Listing Rank is "0" for every free listing and a "9xx" number for
each Verified one, reshuffled every night by the sync with the day as
the seed. So Verified spaces always sit above free ones, take turns
at the top among themselves, and the free listings below are ordered
by WiFi rating, then reviews. A freshly Verified page carries "1"
until that night's rotation, which still sorts above "0".

## 3. The Book Your Desk button

Every listing page already has a Book Your Desk button that opens
the reservation-request modal, whose submissions arrive at
hello@nomadwise.io as Webflow form emails. Keep that for free
listings: it is the lead Nomadwise can forward to the owner with the
Verified offer attached. For Verified listings the same button should
go to the owner directly, through Nomad Maps.

On the Coworking template, duplicate the Book Your Desk button so
there are two, styled the same:

1. The existing one (opens the modal): conditional visibility, show
   when Enquiries On is Off.
2. The copy: make it a link button, set its link to
   `https://nomadmaps.io/?enquire=`, give it the ID `enquire`
   (element settings), conditional visibility, show when Enquiries On
   is On.

Then add this to the page's custom code, before the closing body tag,
so the second button carries the listing's own slug:

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

The Nomad Maps form asks the nomad what they want, dates, people and
a note, and emails the request to the listing's Enquiry Email with a
copy to hello@nomadwise.io. Nomad Maps switches Enquiries On for every
Verified listing, so the swap happens on its own per page.

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

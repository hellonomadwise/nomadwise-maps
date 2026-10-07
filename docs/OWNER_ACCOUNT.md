# The Owner account (nomadmaps.io/owner)

Built 24 September 2026 from Jonathan's concept pages of 21 Sep
(owner journey, members area), within what was agreed with Leonie:
no analytics, no separate perks, pay first and approve after. To an
owner it is "Owner account" and "Manage my listing", branded
"nomadwise for spaces"; "members area" stays internal.

The address people are given is nomadmaps.io/owner (and
nomadmaps.io/claim for the claim form). Those are two tiny pages in
`app/web/owner/` and `app/web/claim/` that forward to the app's
`?owner` and `?claim` doors, keeping whatever the sign-in link
appends. Supabase's redirect allow list holds `https://nomadmaps.io/**`,
which covers them.

## What an owner can do

Sign in with the email an approved claim recorded on their space
(`venues.listing_owner_email`): a sign-in link by email, or Google
when that email is a Google account. No password.

**My listing.** Description, prices (day, week and month pass for a
coworking; cappuccino for any), opening hours per day, the eleven
work-friendly facts, up to five photos, website, Instagram, WhatsApp
and, on a Verified page, the address booking requests go to. A live
preview shows the page as they type. Save draft keeps it private;
Submit for review sends it to the control centre.

The form opens with the page as it is (5 Oct 2026, migration 135): the
page's own text, the photos on the page, the hours Google shows when
the owner has set none (saved as theirs only once a day is changed),
and the passes the page already lists (to look at; changing them from
here is still to build). The preview has a Phone / Computer switch,
and its tags open "What is true for your space?" with what each tag
means.

**Your message** (Verified only; a free page sees why and a Go
Verified button). An event, offer or announcement with a headline,
text, button label and link. It replaces the advert slot on their
page. Clearing the headline and submitting takes it down.

**Membership.** Verified since, renews on, what is included, and how
to cancel (Stripe portal link when `AppConfig.stripePortalLink` is
set, otherwise the receipt link). A free page sees what Verified adds
and a Go Verified button into the claim form.

## Review

Every submission is a draft (`owner_drafts`) until a founder reads it
in the control centre, tab **Owner changes**. The card shows each
field the owner changed with the old value struck through, the
photos, and two buttons: **Put it on the page** and **Send back**
(with a note the owner sees in their account). Putting it on copies
the draft to `venues.owner_content` and the ordinary columns (hours,
facts, website, Instagram, enquiry email, `website_photos`), and
asks the sync to write the page. A phone ping arrives on submission.

## How it reaches the page

`webflow_sync.py`, `owner_fields()`, run by the listing sync within
minutes of approval:

| Owner field | Webflow field |
|---|---|
| Description | `more-info-rich-text` (More Info, the description visitors see) and `best-text` (Best Text, used elsewhere on the site) |
| Prices | cappuccino only in `price-of-coffee` (Cappuccino Price); day, week and month passes as lines after the description in More Info |
| Hours | the seven day fields |
| Facts | the eleven fact fields, same words as before |
| Website, Instagram | `website-url`, `instagram` |
| WhatsApp | `whatsapp` as a wa.me link |
| Photos | `website_photos` on the venue, so the Images entry follows the existing photo path |
| Message (Verified) | `discount-available-2` ("Nomadwise Offers"), one JSON string the site snippet renders |

No new Webflow fields: the collection is at the 60-field limit, so
the message rides in the "Nomadwise Offers" text field. That field
once held the label of a discount button; on 7 Oct 2026 five pages
still had the words "Nomadwise Offers" in it (SOKKOOL, DEOS, Setter
Ubud, Working on Air, AT 06), shown nowhere on the page.

## "Managed by its owner" (7 Oct 2026, migration 157)

A page whose space has an owner should not go on saying "Own or manage
this space? Claim this listing for free". The same field carries the
mark: `{"claimed": true}`, alone or inside the owner's message. So the
field is set exactly when the space has an owner, and the template
needs no code, only conditional visibility:

1. The block with "Own or manage this space?" and the claim link
   (`div-block-842`): visible when **Nomadwise Offers is not set**.
2. A new text block beside it, "Managed by its owner": visible when
   **Nomadwise Offers is set**.

Which pages are marked is decided in the database
(`listing_has_owner`: an owner's address on the space, our own test
claims left out) and written by the website sync (`owner_marks()` in
`webflow_sync.py`), which touches only that field. A new claim is
marked within about ten minutes of its approval; a claim later marked
as a test is unmarked the same way. A listing sync rewrites the
owner's message and leaves the mark as it found it.

## Designer work (Jonathan, once)

1. **Best Text and More Info on the Coworking template.** Check both
   rich text blocks are placed (a "About the space" section and a
   "Prices" section) and each is set to hide when the field is empty
   (Conditional visibility: field is set). Pages without owner text
   then look exactly as today.
2. **The advert slot.** Give each sidebar advert wrapper (the two
   "Collection List Wrapper 18", desktop and phone) the custom
   attribute `data-advert-slot` = `yes`. Add a hidden Text Block anywhere on the template,
   bind it to "Nomadwise Offers", set its ID to `owner-message` and
   `display: none`. The site-wide footer snippet (below) reads it and
   draws the owner's card in place of the advert when the field has a
   message and the Verified switch is on.
3. Publish.

Add this to the site-wide footer code, after the claim-link snippet:

```html
<script>
document.addEventListener('DOMContentLoaded', function () {
  var src = document.getElementById('owner-message');
  var slots = document.querySelectorAll('[data-advert-slot], #advert-slot');
  if (!src || !slots.length) return;
  var raw = (src.textContent || '').trim();
  if (!raw || raw.charAt(0) !== '{') return;
  var m; try { m = JSON.parse(raw); } catch (e) { return; }
  if (!m.title) return;
  function esc(t) { return String(t || '').replace(/[&<>"]/g, function (c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  var name = (document.querySelector('h1') || {}).textContent || 'this space';
  var url = /^https?:\/\//.test(m.url || '') ? m.url : '';
  var card =
    '<div style="background:#E8F8F9;border:1px solid #ADE9EC;border-radius:14px;padding:18px 20px;">' +
    '<div style="font-size:11px;letter-spacing:.08em;font-weight:700;color:#004854;text-transform:uppercase;">From ' + esc(name) + '</div>' +
    '<div style="font-size:12px;color:#5C6773;margin-top:6px;">' + esc(m.kind || 'Event') + '</div>' +
    '<div style="font-size:19px;font-weight:800;margin-top:4px;color:#142032;">' + esc(m.title) + '</div>' +
    (m.body ? '<div style="font-size:14px;line-height:1.5;margin-top:6px;color:#142032;">' + esc(m.body) + '</div>' : '') +
    (url ? '<a href="' + esc(url) + '" rel="nofollow noopener" target="_blank" style="display:inline-block;margin-top:12px;background:#004854;color:#fff;font-weight:700;padding:10px 16px;border-radius:4px;text-decoration:none;">' + esc(m.cta || 'Find out more') + '</a>' : '') +
    '</div>';
  // Also where no advert runs for that place: a list switched off by
  // Webflow's conditional visibility is shown again, holding the card.
  slots.forEach(function (s) {
    s.classList.remove('w-condition-invisible');
    s.innerHTML = card;
  });
});
</script>
```

The snippet only ever replaces the one element with that ID, so no
other advert on the site is touched.

## Emails (Postmark, migration 81)

"Your changes are on the page", "We sent your changes back", the
approval and page-live emails, and the sign-in link all go through
Postmark once its server token is in the Vault
(docs/POSTMARK_SETUP.md). Until then each is logged as skipped in
`owner_emails`, the sign-in link still arrives from Supabase's
built-in sender (a handful an hour), and the owner learns a decision
by looking in their account.

## Inbox & support (7 Oct 2026, migration 161)

A fifth tab: the owner's chat with Nomadwise about the space. They
write, the founders' phones are told, and the answer appears there and
is emailed to them. A number beside the tab says how many messages
from us are unread; opening the tab clears it and shows us two ticks.
The email's button leads to `nomadmaps.io/owner?chat=<space>`, which
opens that space on this tab. The founders answer from Chats in the
team tools, or from nomadmaps.io/chats on a phone.

The note above the box reads "Your message goes straight to the
Nomadwise team. Our reply appears here and is also emailed to you, so
you will not miss it." Jonathan, 7 Oct: nothing in owner-facing copy
says we are a small team; the voice is that of an established company.
It also makes no promise about how fast we answer.

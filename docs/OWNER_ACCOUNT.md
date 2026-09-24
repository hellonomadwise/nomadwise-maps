# The Owner account (nomadmaps.io/?owner)

Built 24 September 2026 from Jonathan's concept pages of 21 Sep
(owner journey, members area), within what was agreed with Leonie:
no analytics, no separate perks, pay first and approve after. To an
owner it is "Owner account" and "Manage my listing", branded
"nomadwise for spaces"; "members area" stays internal.

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
| Description | `best-text` (Best Text, rich text) |
| Prices | `more-info-rich-text` (More Info), one line per price; cappuccino also in `price-of-coffee` |
| Hours | the seven day fields |
| Facts | the eleven fact fields, same words as before |
| Website, Instagram | `website-url`, `instagram` |
| WhatsApp | `whatsapp` as a wa.me link |
| Photos | `website_photos` on the venue, so the Images entry follows the existing photo path |
| Message (Verified) | `discount-available-2` ("Nomadwise Offers"), one JSON string the site snippet renders |

No new Webflow fields: the collection is at the 60-field limit, so
the message rides in the unused "Nomadwise Offers" text field.

## Designer work (Jonathan, once)

1. **Best Text and More Info on the Coworking template.** Check both
   rich text blocks are placed (a "About the space" section and a
   "Prices" section) and each is set to hide when the field is empty
   (Conditional visibility: field is set). Pages without owner text
   then look exactly as today.
2. **The advert slot.** Give the sidebar advert element the ID
   `advert-slot`. Add a hidden Text Block anywhere on the template,
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
  var slot = document.getElementById('advert-slot');
  if (!src || !slot) return;
  var raw = (src.textContent || '').trim();
  if (!raw || raw.charAt(0) !== '{') return;
  var m; try { m = JSON.parse(raw); } catch (e) { return; }
  if (!m.title) return;
  function esc(t) { return String(t || '').replace(/[&<>"]/g, function (c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  var name = (document.querySelector('h1') || {}).textContent || 'this space';
  var url = /^https?:\/\//.test(m.url || '') ? m.url : '';
  slot.innerHTML =
    '<div style="background:#E4F2EA;border-radius:14px;padding:18px 20px;">' +
    '<div style="font-size:11px;letter-spacing:.08em;font-weight:700;color:#1F6B41;text-transform:uppercase;">From ' + esc(name) + '</div>' +
    '<div style="font-size:12px;color:#5C6773;margin-top:6px;">' + esc(m.kind || 'Event') + '</div>' +
    '<div style="font-size:19px;font-weight:800;margin-top:4px;color:#142032;">' + esc(m.title) + '</div>' +
    (m.body ? '<div style="font-size:14px;line-height:1.5;margin-top:6px;color:#142032;">' + esc(m.body) + '</div>' : '') +
    (url ? '<a href="' + esc(url) + '" rel="nofollow noopener" target="_blank" style="display:inline-block;margin-top:12px;background:#1F6B41;color:#fff;font-weight:700;padding:10px 16px;border-radius:9px;text-decoration:none;">' + esc(m.cta || 'Find out more') + '</a>' : '') +
    '</div>';
});
</script>
```

The snippet only ever replaces the one element with that ID, so no
other advert on the site is touched.

## Emails still to come (Resend)

"Your changes are on the page", "We sent your changes back", and the
sign-in link through Resend instead of Supabase's built-in sender,
which is rate limited to a handful an hour. Until then the sign-in
link still arrives, just from Supabase, and the owner learns a
decision by looking in their account.

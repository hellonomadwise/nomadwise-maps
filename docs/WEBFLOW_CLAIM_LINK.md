# The claim link on every listing page

The line "Is this your business? Claim, customise and enhance your
profile." on the Coworking template points at the claim form. Two
Designer steps and one snippet of page code; the snippet makes the
link carry the page it was clicked on, so the claim form opens on the
right space and the phone ping says where the visitor came from.

## 1. The link (Designer)

Coworking Template page, select the "Is this your business?" link and
set its URL to `https://nomadmaps.io/?claim`, open in new tab. No ID
needed: the snippet finds any link pointing at the claim form.

## 2. The snippet (page settings)

Pages, hover the Coworking Template, cog, Custom code, "Before
</body> tag", at the very end:

```html
<script>
document.addEventListener('DOMContentLoaded', function () {
  var slug = location.pathname.split('/').filter(Boolean).pop() || '';
  var here = location.pathname;
  document.querySelectorAll('a[href*="nomadmaps.io/?claim"]').forEach(function (a) {
    a.href = 'https://nomadmaps.io/?claim=' + encodeURIComponent(slug) +
             '&from=' + encodeURIComponent(here);
  });
  var b = document.getElementById('enquire');
  if (b) b.href = 'https://nomadmaps.io/?enquire=' + encodeURIComponent(slug);
});
</script>
```

(The `enquire` part is for the Verified booking button from
WEBFLOW_VERIFIED_SETUP.md; harmless until that button exists.)

Save, Publish. Without the snippet the ping can only say "from
nomadwise.io/", because browsers pass no more than the site name
between two different sites.

## What happens then

- `?claim=<slug>` opens the claim form with that space already chosen,
  straight on the "About you" step. A slug that is not found (or a page
  that is already Verified) falls back to the normal search.
- `&from=/coworking/<slug>` is logged in `claim_visits` and named in
  the phone ping: "Someone opened the claim page for Neighbors and
  Nomads Coworking in El Nido, from nomadwise.io/coworking/...".
  Visits from elsewhere show the browser's referrer (google.com, a
  newsletter) or "direct".
- Pings are capped at 30 an hour; the log keeps every visit.

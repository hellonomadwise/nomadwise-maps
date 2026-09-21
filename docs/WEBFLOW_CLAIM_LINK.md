# The claim link on every listing page

The line "Is this your business? Claim, customise and enhance your
profile." on the Coworking template points at the claim form. Two
Designer steps and one snippet of page code; the snippet makes the
link carry the page it was clicked on, so the claim form opens on the
right space and the phone ping says where the visitor came from.

## 1. The link (Designer)

Coworking Template page, select the "Is this your business?" link
(click the text, then check the breadcrumb says Link or Text Link).
Settings panel (press D):

- Link: URL, `https://nomadmaps.io/?claim`
- Open in new tab: on
- ID: `claim-link`

## 2. The snippet (page settings)

Pages, hover the Coworking Template, cog, scroll to Custom code,
"Before </body> tag". Paste:

```html
<script>
  (function () {
    var slug = location.pathname.split('/').filter(Boolean).pop() || '';
    var here = location.pathname;
    var a = document.getElementById('claim-link');
    if (a) {
      a.href = 'https://nomadmaps.io/?claim=' + encodeURIComponent(slug) +
               '&from=' + encodeURIComponent(here);
    }
    var b = document.getElementById('enquire');
    if (b) {
      b.href = 'https://nomadmaps.io/?enquire=' + encodeURIComponent(slug);
    }
  })();
</script>
```

(The second block is for the Verified booking button from
WEBFLOW_VERIFIED_SETUP.md; harmless until that button exists.)

Save, Publish.

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

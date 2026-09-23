# Page tracker: new pages vs existing (PostHog)

Dashboard: "Directory: new pages vs existing" in the Nomadwise PostHog
project (eu.posthog.com, dashboard 970232). Made 23 September 2026.

How "new" is decided: PostHog has recorded every page view on
nomadwise.io since November 2025, so a page is NEW when its first
ever page view is on or after 13 September 2026 (the control centre
launch), and EXISTING otherwise. No list is sent from the database;
nothing runs nightly. The cutoff is a date written in each chart's
SQL (`toDateTime('2026-09-13')`); change it there to move it. Listing
pages are `/coworking/…`; directory pages are `/region/…`,
`/locations/…` and `/country/…`.

Known limits: an old page that never had a single view before the
cutoff would count as new (rare: in mid-2026 only a handful of old
pages a month had their first view). PostHog only sees visitors who
run its script, so ad blockers and consent choices reduce the counts
equally for both groups. The founders' own visits are counted; in the
first days after a page goes live most of its views are ours.

Charts: weekly views new vs existing (listings; directory pages),
views per page per week (the fair comparison), a 30-day scorecard
with the share of views arriving from Google (the number to watch:
new pages start near zero and climb as Google indexes them), the
list of new pages one row each, and new pages arriving per week.

Google Search Console would add impressions and clicks per page,
which PostHog cannot see; that needs a service account and a nightly
pull, and is not built.

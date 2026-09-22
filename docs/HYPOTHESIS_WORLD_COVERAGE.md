# Hypothesis: every cafe, coworking and coliving space a nomad might look for

Written 22 September 2026. A hypothesis, not a commitment.

## Three problems, not one

1. **Finding candidates** is nearly free (open map data).
2. **Verifying** them with Google costs per place.
3. **Screening** them for "can I work here" is the thing nobody else
   does, and stays with nomads in the app.

Never pay Google to discover places; only ask Google about places
already worth asking about.

## Layers

1. **Seed, free.** Overture Maps Places (open, tens of millions of
   places with categories and coordinates) and OpenStreetMap (cafes;
   a thin set of coworking spaces, some tagged with WiFi and power).
   Nightly job pulls every cafe and coworking candidate per city into
   `candidate_places`. Replaces the paid Nearby Search discovery step.
2. **Prioritise, free.** Rank cities by demand (nomadwise.io traffic,
   app usage, a hand list of hubs); rank candidates within a city by
   free signals (category, name, OSM tags, proximity to confirmed
   spaces). A few hundred cities cover most demand.
3. **Verify, paid but paced.** Match to Google (Text Search Pro,
   ~$32 per 1,000), pull details (Place Details Pro, ~$17 per 1,000),
   review scan (dearer tier), photos resolved once (~$7 per 1,000
   photo loads). About ten cents per fully screened place. Google's
   free monthly allowance per tier (about 5,000 mid-tier and 1,000
   top-tier calls) means a sweep paced to it verifies thousands of
   places a month for nothing. Pre-filtering to the promising third
   of candidates cuts the bill further. Tens of thousands of screened
   places is a year of nightly work; a million is six figures and
   pointless.
4. **Screen, nomads.** Review scan flags promising; nomads confirm
   and earn coins (built). This gate is the moat.
5. **Publish, curated.** Webflow holds confirmed spaces only; the app
   map shows candidates and promising places too. Already the split
   between `discovered_places` and `venues`.

## Coliving

Not in map data. Sources: coliving directories and booking sites,
plus a Google text search per city. A few thousand worldwide. A
separate cheaper sweep and a new place type in the app.

## To build

- Overture/OSM ingest job and `candidate_places` table.
- City priority list (data-driven, editable).
- Verifier that spends exactly the free monthly allowance unless a
  budget is set; dedupe against `venues` and `discovered_places`.
- Coliving type and sweep.
- `city_sweeps` and `sweep_queue` are the skeleton; the free seed
  goes in front of them.

Prices as published for the Places API (New) in 2026; check before
budgeting.

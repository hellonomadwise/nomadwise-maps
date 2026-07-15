# Nomadwise Maps

A maps-first mobile app (iPhone + Android, built with Flutter) that helps
digital nomads find cafes and coworking spaces they can actually work from.

**Core promise:** every pin answers one question — *can I work here, or skip it?*

- 🔴 Red gradient pin — laptops welcome (work-friendly)
- ⚪ Grey pin — not for laptops
- 🟡 Amber-outline pin — unknown: confirm it and earn coins

## How it's put together

| Piece | Where |
|---|---|
| App code (Flutter) | `app/` |
| Database & security rules | `supabase/schema.sql` |
| Lisbon seed venues (33) | `supabase/seed.sql` |
| Brand assets | `app/assets/brand/`, pins in `app/assets/pins/` |
| Build & web preview | `.github/workflows/build.yml` (GitHub Actions → GitHub Pages + APK) |
| Coordinate enrichment | `.github/workflows/enrich.yml` (one-off, fills lat/lng from Google) |
| Future features (planned, not built) | `app/lib/future/README.md` |

## Data flow

- **Supabase** holds venues, users, submissions, and the coin ledger.
  Coins are awarded by database triggers (100 new venue / 30 confirm),
  start as *pending*, and only become *withdrawable* when a submission is
  verified (required photo + GPS proximity check). Cash-out at 5,000 coins = €50.
- **Google Places API** supplies live data per venue via its Place ID:
  star rating, review count, open/closed now, opening hours — and the
  "closes in X / closing soon" labels are computed from those hours.
- Distance is computed on the phone from the user's location.

## Keys (GitHub repository secrets)

`SUPABASE_URL` · `SUPABASE_ANON_KEY` · `SUPABASE_SERVICE_ROLE_KEY` (enrich only) ·
`GOOGLE_PLACES_KEY` · `GOOGLE_MAPS_ANDROID_KEY` · `GOOGLE_MAPS_WEB_KEY` ·
`GOOGLE_MAPS_IOS_KEY` (used by Codemagic later)

No key lives in the source code; CI injects them at build time.

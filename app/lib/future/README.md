# Future features (structure ready, not built yet)

Per Jonathan's brief these are explicitly NOT built yet — this folder keeps
their place in the architecture so they slot in without reshuffling.

## 1. In-app wifi speed test (`wifi_speed_test.dart`)
- Measures download/upload while the user sits in the venue and auto-fills
  `wifi_speed_mbps` on the Add/Confirm form (the form already has the field
  and a helper note pointing to this).
- Plan: download a test payload from a CDN, measure throughput; save to the
  submission payload. No schema change needed (`wifi_speed_mbps` exists).

## 2. Wifi passwords + one-tap auto-connect (`wifi_passwords.dart`)
- New table `venue_wifi (venue_id, ssid, password, updated_at, verified)`.
- Auto-connect uses platform wifi APIs (Android `wifi_iot`; iOS is more
  restrictive — likely NEHotspotConfiguration, needs entitlement).
- Passwords gated behind premium (below).

## 3. Premium tier + super-user perk (`premium.dart`)
- `profiles.premium_until timestamptz` column.
- Unlocks all wifi passwords.
- Super-user perk: contribute >= N verified submissions per calendar month
  -> premium free that month. Compute from `submissions` at read time or a
  monthly cron; the `coin_ledger`/`submissions` tables already give a full
  audit trail so no new tracking is needed.

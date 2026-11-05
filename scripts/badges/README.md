# Website badges (CR-26)

The badges in app/web/badges are Leonie's final design files (5 Nov 2026,
her "nomadwise-media-pack.zip"), renamed for the app and with the corners set
to 8px (house rule; her files had 10px):

| Her file | In app/web/badges |
|---|---|
| 1-white/svg/nomadwise-free-pill.svg | find-line.svg |
| 1-white/svg/nomadwise-plus-square.svg | verified-square.svg |
| 2-red/... | ...-red.svg |
| 3-transparent-white/... | ...-outline.svg |

"plus" in her names is Premium. Pill 210x44 (free) / 212x44 (Premium), square
104x104. The .png files beside them are made from the SVGs with Playwright (2x
for the Owner account preview, -large 4x); the media pack ZIPs keep her
layout (1-white, 2-red, 3-outline; svg and png @1x/@2x/@3x) with "premium" in
place of "plus".

gen.py, logo.py and png.py are the earlier generated version (5 Nov), kept
only as a reference; logo_icon_paths.txt is the round logo from the site's
SVG, also in brand/nomadwise-icon.svg (colour) and brand/nomadwise-icon-white.svg.

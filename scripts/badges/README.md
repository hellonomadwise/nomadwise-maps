# Website badges (CR-26)

How the badges in app/web/badges are made. Run from this folder:

1. Fonts: `npm pack @fontsource/roboto@5.1.0`, unpack to `fontpkg/`, then turn
   `roboto-latin-500/700-normal.woff` into `roboto-500.ttf` / `roboto-700.ttf`
   with fontTools. `pip install uharfbuzz`.
2. `python3 gen.py svg` writes the 12 SVGs (text drawn as shapes, so they look
   the same everywhere) and sizes.json.
3. `python3 png.py svg png` writes the PNGs (2x for the Owner account preview,
   -large 4x for the media pack) with Playwright.

logo_icon_paths.txt is the round logo from the site's nomadwise-io-logo-red.svg.
logo.py draws it in colour, or as the white line version (ring, palms and sun
filled, clouds and waves as lines) for the Red and Outline badges. The same two
icons are in brand/nomadwise-icon.svg and brand/nomadwise-icon-white.svg.

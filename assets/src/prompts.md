# TileCam README artwork

## Reference inspected first

[Pinch assets](https://github.com/RainnWorks/pinch/tree/main/assets): viewed
`hero.png` and `how-it-works.png`, and inspected `src/prompts.md`, `src/render.py`
and the SVG layout sources before drawing TileCam artwork. The visual model is
white technical contours, plain sans-serif labels, thin connectors and a solid
black canvas. No Pinch artwork is included in these deliverables.

## Exact image-generation prompt

Tool: built-in `image_gen`, one generation call. No CLI/API fallback.
The unchanged returned raster is `objects-generated.png` (1280 × 1280; the
requested 1536 size was advisory). The same exact prompt is in
`objects-prompt.txt`.

```text
Use case: scientific-educational
Asset type: reusable object drawings for TileCam README artwork, matching sparse white technical line art on pure black.
Primary request: Draw four separate objects in a strict 2 by 2 contact sheet, each isolated in its own quadrant with generous black margins. Top left: a small indoor pan-tilt home security camera with a rounded dome head and short circular base, three-quarter view. Top right: an outdoor bullet security camera with a short mounting arm and wall plate, three-quarter view, lens facing left. Bottom left: a compact upright doorbell camera with a prominent round lens, three-quarter view. Bottom right: an Apple Watch with simple sport band above and below, front view, completely empty black screen.
Style/medium: clean white technical contour line drawings, black interiors, sparse curved construction contours, recognizable silhouettes. Uniform white strokes approximately 5 pixels at 1536 square resolution. Pure black (#000000) background. Each object centered in its quadrant, fully visible, with no overlap. Square 1536 by 1536 composition.
Constraints: Draw only the four objects. No text, letters, numbers, labels, logos, arrows, leader lines, diagram boxes, icons, screen content, shading, gradients, glow, shadows, hands or scenery. Camera lenses are empty concentric contours. Watch display is completely blank. Do not draw contact-sheet borders.
```

Only the three camera objects and blank Apple Watch are model-generated.
The iPad bezel is an exact-fit SVG rounded rectangle, with its camera mark also
in SVG. All labels, arrows and boxes are SVG. No generated text or feed
content is used.

## Retained sources

- `objects-generated.png`: original generated master, unmodified.
- `indoor.png`, `bullet.png`, `doorbell.png`, `watch.png`: deterministic crops.
  `render.py` trims each quadrant, clears low-level background noise, and
  strengthens the white contours for small-screen legibility.
- `render.py`: source of truth for composition and raster preparation. It reads
  the hero screenshot from `fastlane/screenshots/en-US/1_ipad13_grid.png` and
  copies the icon from `GlassView/Assets.xcassets/AppIcon.appiconset/icon-1024.png`,
  so a new App Store screenshot or app icon is picked up on the next run. The
  whole portrait screenshot is scaled uniformly to 510 × 680: no tiles are moved,
  no feed is invented, no crop is applied. The icon is copied unchanged.

## Exact compositing commands

From the repository root, on Debian/Ubuntu:

```sh
apt-get update -qq
apt-get install -y -qq python3-pil librsvg2-bin fonts-liberation
python3 assets/src/render.py
```

`render.py` copies the shipping icon, prepares object crops with Pillow, writes
`hero.svg` and `how-it-works.svg` to a temporary folder, rasterizes them with
`rsvg-convert`, and saves opaque RGB PNGs. The SVGs and the review previews
(900 px, 390 px, icon at 32 px and 16 px) stay in that temporary folder, which
it prints.
The font is Liberation Sans, deliberately fixed for repeatable line lengths.
No image generation is needed to rebuild the committed output.

To regenerate only object artwork, send the exact prompt above to built-in
`image_gen`, save the result as `assets/src/objects-generated.png`, then run the
render command. Inspect the quadrant boundaries if the model changes placement.

## Composition and review

Hero: 1800 × 900. Three camera silhouettes and the labels Tapo, Reolink, UniFi,
ONVIF / RTSP lead through one arrow to the actual six-feed TileCam screenshot.
The labels name camera families; the drawings are generic representative objects.
Portrait preserves all six feeds and the original app interface.

Flow: 1800 × 850. Camera (RTSP / ONVIF) → go2rtc (your server) → TileCam
(iPhone, iPad, Mac), with WebRTC on the server-to-app arrow. The heavier
outlined go2rtc box is mandatory in the path; no line connects Camera directly
to TileCam. The only lower branch begins beneath iPhone and passes through the
Watch button before the snapshots + audio arrow to Apple Watch. There are three
outlined boxes, below the five-box maximum. The Watch screen is intentionally
blank, not a fabricated app screenshot.

Visual checks use `view_image`: final outputs at full size, 900px and 390px
previews, generated master and prepared object crops, and native icon previews.
Solid black canvases preserve contrast on both light and dark GitHub pages.
At 390px, camera silhouettes, the real grid, primary labels and both flow paths
remain readable; small screenshot UI and feed details naturally require zoom.

Shipping icon review: at 32px the four-tile grid and circular camera lens are
clear. At 16px the grid and lens still read, though the small lens highlight and
rounded corners soften. It remains recognizable at both sizes. No icon changes
were made.

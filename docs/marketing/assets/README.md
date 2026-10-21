# Brand assets

Source of truth for the Fillline mark, the app icon, and the GitHub social card.
Everything here is one accent family on one paper/ink palette; nothing else ships.

| File | Role | Size |
|---|---|---|
| `app-icon-source.svg` | **master.** The only place the mark is drawn. | 1024 × 1024 vector |
| `../../Resources/AppIcon.iconset/` | generated from the master, 10 PNGs | 16 → 1024 |
| `../../Resources/AppIcon.icns` | `iconutil` bundle of the iconset | 801,208 bytes |
| `og-image.svg` | GitHub social preview, editable source | 1280 × 640 vector |
| `og-image.png` | the file GitHub actually serves | 1280 × 640 |
| `icon-legibility.png` | review proof sheet (16/32/64/128/512, light / dark / greyscale) | 1740 × 1180 |

Rule: **the master is the SVG.** Never edit a PNG, and never let a PNG become the
reference for the shape. The `.icns` is a build product; it is committed so a checkout
can build the app bundle without running Chrome.

## 1. The mark

A sight glass in a tank plate: a rust volume for the quota that is left, and the level
drawn as one bright line that overshoots the glass on both sides — the same tick that
overshoots every meter in the popover, grown up. It is the product's own row, at icon
scale, and it is why the mark needs no dial, needle, letter or provider glyph.

Construction, in the master's 1024 grid:

- **tile** — full-bleed superellipse, centre 512,512, exponent 4.6, radius 512. That is
  the ≈22 % corner feel of a macOS 26 icon; it is slightly flatter than a circular
  rounded rect. The path is a Catmull-Rom fit of the parametric superellipse, so
  regenerate it rather than editing its numbers.
- **glass** — x 192…832, y 148…876, radius 176. The headroom above the level is a
  recessed chamber (`#080706` at 34 → 12 % over the plate), not a lighter pane: a lighter
  pane greys the fill line out at 16 px.
- **level** — y 448, i.e. 59 % of the glass height from the floor.
- **fill line** — x 144…880, y 384…448, thickness 64, square ends. It sits tangent to
  the liquid surface and overshoots the glass by 48 on each side.
- **grid** — every edge is a multiple of 16, so the line lands on an exact pixel row at
  16, 32, 64, 128, 256 and 512 px. Moving it by 8 units makes it straddle two rows at
  16 px and it goes grey. This is the one constraint worth keeping.

## 2. Palette

| Token | Value | Use |
|---|---|---|
| paper | `#F2EFE8` | palette paper; the fill line core is `#FEFBF4 → #F5F2EA → #DAD3C2` |
| ink | `#1A1915` | palette ink; plate gradient `#332D26 → #1F1C18 → #100F0C` |
| rust | `#A6432A` | palette rust; liquid gradient `#C85F39 → #C05B36 → #A6432A` |
| recess | `#080706` @ 34 → 12 % | the empty headroom behind the glass |
| muted | `#5F5B53` | OG body copy, captions |
| tertiary | `#8D877C` | OG labels, kickers |

One accent, one hue family. There is no green, no blue, no gradient between hues, and no
second highlight colour anywhere in these files. Rust appears on the volume, the fill
line's neighbours, the OG meter and the OG footer rule — nowhere else.

## 3. Rebuilding

Chrome is the rasteriser (it is the only one on this machine that renders all of the
gradients and the squircle path faithfully). `rsvg-convert` also works but shifts the
sub-pixel edges; `sips` cannot read SVG.

### App icon

Each iconset size is rasterised from the vector **at its own size**. Do not downsample
the 1024 master: Lanczos turns the 64-unit fill line into two half-grey rows at 16 px,
which is exactly the mush the 16 px test is looking for.

```bash
REPO=$(git rev-parse --show-toplevel)
SVG="$REPO/docs/marketing/assets/app-icon-source.svg"
OUT="$REPO/Resources/AppIcon.iconset"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

render () {                      # $1 = pixel size
  cat > /tmp/icon-$1.html <<EOF
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:transparent;overflow:hidden}
img{display:block;width:$1px;height:$1px}</style></head>
<body><img src="file://$SVG"></body></html>
EOF
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --default-background-color=00000000 \
    --window-size=$1,$1 --screenshot=/tmp/icon-$1.png /tmp/icon-$1.html
}

for s in 16 32 64 128 256 512 1024; do render $s; done

cp /tmp/icon-16.png   "$OUT/icon_16x16.png"
cp /tmp/icon-32.png   "$OUT/icon_16x16@2x.png"
cp /tmp/icon-32.png   "$OUT/icon_32x32.png"
cp /tmp/icon-64.png   "$OUT/icon_32x32@2x.png"
cp /tmp/icon-128.png  "$OUT/icon_128x128.png"
cp /tmp/icon-256.png  "$OUT/icon_128x128@2x.png"
cp /tmp/icon-256.png  "$OUT/icon_256x256.png"
cp /tmp/icon-512.png  "$OUT/icon_256x256@2x.png"
cp /tmp/icon-512.png  "$OUT/icon_512x512.png"
cp /tmp/icon-1024.png "$OUT/icon_512x512@2x.png"

rm -f "$REPO/Resources/AppIcon.icns"
iconutil -c icns "$OUT" -o "$REPO/Resources/AppIcon.icns"
```

Then check the result, every time:

```bash
for f in "$OUT"/*.png; do
  printf "%-24s " "$(basename "$f")"; sips -g pixelWidth -g pixelHeight "$f" | tail -2 | tr -d '\n'; echo
done
file "$REPO/Resources/AppIcon.icns"        # expect: Mac OS X icon, "ic12", > 100 000 bytes
iconutil -c iconset "$REPO/Resources/AppIcon.icns" -o /tmp/roundtrip.iconset
```

The screenshot must be exactly square and the tile must touch all four edges — a
scrollbar, a page margin or a centred image would letterbox it. If a corner pixel is not
transparent, the tile is being drawn inside a page box, not full bleed.

### OG card

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SRC="$REPO/docs/marketing/assets/og-image.svg"
printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;overflow:hidden}img{display:block}</style><img src="file://%s" width="1280" height="640">' "$SRC" > /tmp/og.html
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=FFFFFFFF --window-size=1280,640 \
  --screenshot="$REPO/docs/marketing/assets/og-image.png" /tmp/og.html
```

`og-image.svg` embeds a copy of the icon master inside a nested `<svg>` (ids prefixed
`ic-`) so the card is one self-contained file. If the master changes, replace that
block — it is a copy, not a link.

The headline is verbatim from `docs/marketing/copy.md` §2 ("README hero"), which is the
copy source of truth: change it there first, then rebuild the card. The provider line and
`READ-ONLY · NO TELEMETRY` are the same claims the README makes, in the same words.

The 62 % on the card is the menu bar's own sample value (`C 62%` in the UI specimen);
`38% used` and `resets in 3h 12m` are consistent with it, so the drawing adds up. It is
one row, not a reading from anyone's account, and the card carries no window chrome, so
it cannot be mistaken for a screenshot the app never produced.

### Proof sheet

`icon-legibility.png` is a review artifact, rebuilt by hand: a plain HTML page that
places the iconset PNGs at 16, 32, 64, 128 and 512 at **1:1**, on `#EFEBE1`, `#1B1B1A`
and a neutral grey, and rasterised with the same headless Chrome command at 1740 × 1180.
The 16 and 32 px copies are repeated at ×8 / ×4 with `image-rendering: pixelated` so a
reviewer can see the pixels that actually survive. Nothing in it is upscaled for the
real-size rows; that is the whole point of the sheet.

## 4. Results on record

**Measured sizes** (`sips -g pixelWidth -g pixelHeight`): `icon_16x16` 16, `icon_16x16@2x`
32, `icon_32x32` 32, `icon_32x32@2x` 64, `icon_128x128` 128, `icon_128x128@2x` 256,
`icon_256x256` 256, `icon_256x256@2x` 512, `icon_512x512` 512, `icon_512x512@2x` 1024.
`file Resources/AppIcon.icns` → `Mac OS X icon, 801208 bytes, "ic12" type`; the
round-trip returns all ten representations at the same sizes.

**16 px.** What survives: the tile silhouette (14:1 against paper), the rust volume, and
the fill line as one solid paper row (`#EEE9DF`, row 6, x 2…13) — 4.06:1 against the
volume and 14.2:1 against the plate. What is lost: the glass head and its rim, which is
accepted; the mark reads as *tile → volume → line*, which is the whole idea. The
volume's floor is deliberately soft (2.2:1 against the plate) so it reads as a lit
volume rather than a bar; the silhouette is carried by the tile edge, not by that seam.

**Greyscale.** Measured on the 16 px asset after desaturation: the fill-line row is
233/255, the volume 104/255, the plate 29/255 — three separated steps, and every adjacent
pair is above 3:1 (4.06 / 3.49 / 14.18), so the mark is recognisable with no hue at all. That is also why the
volume keeps its light top: the palette rust on its own (`#A6432A`) against the plate is
only 2.8:1, and at that value the mark flattens into a dark chip with a stripe.

**OG card.** 1280 × 640 exactly. The longest text line ("you have left — before you hit
the wall.") ends at x = 581 with the right column starting at x = 744, and the rightmost
element ends at x = 1200 — 80 px inside the card. At a 600 px-wide preview the name is
50 px and the promise 13.6 px, and both were read at that size; the mono eyebrows fall to
about 7 px there and are decorative — the name and the promise are the only text meant to
be read in a preview.

## 5. What not to do

- **No text in the icon.** Not "FL", not "62", not a full stop. At 16 px it is a smudge,
  and the mark has to work in a menu bar where the numbers already live next to it.
- **No provider marks.** No sunburst, no knot, no four-colour shapes. The product is
  provider-agnostic and the name deliberately avoids their trademarks (AGENTS §2, §10).
- **No white sticker border.** The tile is full bleed with its own gradient and inner top
  highlight. A stroke around the plate turns a macOS 26 icon into a web favicon.
- **No external drop shadow.** The canvas is the icon; a baked shadow would either be
  cropped or force a margin around the tile. The OS draws the shadow. Depth comes from
  the plate gradient, the recessed headroom and the 1 px specular on the plate's top edge.
- **No second accent, no hue shift.** Rust is the only accent. Do not "make it pop" with
  amber or green; those are status colours in the app and must not become brand colour.
- **Do not move the fill line off the 16-unit grid,** and do not add a hairline. At
  16 px a stroke under 60 units either disappears or turns grey.
- **Do not flip the meaning.** The volume is *remaining*. An icon that fills as you spend
  contradicts every screen in the product.
- **Do not put a screenshot in the OG card** unless it is a real capture of the real app
  (AGENTS §7.3); a mockup presented as a screenshot is a lie with a nice gradient.

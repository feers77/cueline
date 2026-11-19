# v2ui_assets — the V2 UI's icon set (our own drawings)

`icons.py` (Apache-2.0) is the source of every pictogram the V2 renderer (`mods/v2ui/v2.c`) draws. The icons are
original geometric drawings in the CDJ-3000 manner (thin white outline pictograms) — no firmware is read, nothing
is copied, traced or resampled from Pioneer / AlphaTheta artwork. `mods/v2ui/build.sh` runs it on every build:

```
python3 icons.py <outdir> [--png atlas_preview.png]      # writes <outdir>/v2ui_atlas.c / .h
```

The output is deterministic (byte-identical on every run; the files are only rewritten when they change).

## Sizes (the scaling rule: CDJ-3000 sizes x 0.625)
| class | cell | where |
|---|---|---|
| list pictograms | 16 px (KEY 16x14, BPM 16x12, FOLDER 16x15) | list rows, the side-1 pane, list headers, the SORT strip |
| rail / INFO pictograms | 20 px | the browse rail categories (`v2a_for_rail`), the INFO page fields (`v2a_for_big`) |
| title note | 12x18 (glyph 10x15) | before the title: player header, track rows, browse strip |
| loaded-row play | 8x10 | the loaded track's row (green) |
| source pictograms | USB 13x21, SD 14x18, LINK 22x15, DISC 20x20 | source tile, player header, SOURCE rows, SHORT CUT (centred in the 21-px band, `SRC_DY`) |
| rating stars | 17x16 (in text), 20x20 (filter) | |
| others | delete key 24x16, settings 18x14, Wait spinner 8 x 32x32, no-artwork disc 35x38 / 100x108 / 164x164 | |

Every asset is drawn at the exact size it is shown (no runtime scaling: `icon_scaled` calls are 1:1).

## Pixel fitting
Shapes are authored in target pixels: straight edges sit on whole-pixel boundaries, so 1-px strokes are one solid
pixel column / row. Curves and diagonals are rendered at 16x16 supersampling and reduced by an exact area (box)
filter (alpha = coverage), then `alpha = coverage ** 0.8` (the renderer blends in sRGB, `set_ramp`: without it thin
light strokes on the dark UI read thinner than drawn), quantised to 4 bits. Text inside a pictogram: our own pixel
letters at 16 px (`PIX`: b # B P M), our UI font Cueline Sans (OFL) at 20 px.

## Atlas format (unchanged API)
`v2a_rects[]` (nxs2 model icon id, kind, x, y, w, h), `v2a_mask[]` (4 bpp alpha, 256 px wide, high nibble = left
pixel; identical bitmaps share a place), `v2a_for_icon(id)`, `v2a_for_big(id)`, `v2a_for_rail(id)`. The renderer
tints a mask fg over bg (white normally, green for the loaded row / KEY, grey for INFO labels). There are no colour
(RGB565) assets any more; `v2a_rgb` is a 4-byte stub.

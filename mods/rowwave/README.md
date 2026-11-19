# rowwave — CDJ-3000-style browse rows for the CDJ-2000NXS2

Every TRACK row of the browser shows the track's artwork and colour waveform
in a 112x20 cell, and at the row's right end its file type, BPM, key and
duration ("FLAC 122.0 12B 2:48"). A finger on a row previews that track on
the mixer's LINK CUE (needs `touch_audio`).

## Use

**BROWSE** to any list of tracks from the deck's own USB/SD with a rekordbox
export. The rows fill in as the `TchAud` task draws them, about 0.1 s per
row. Touch a row anywhere between x 33 and 779 to preview it from that point;
lift to stop. Rows that are not tracks (folders, artists, ...) stay stock.

`C:/NOMODS` on the medium switches it off along with `touch_audio`: the rows
go back to the stock number column (the GUI's static pokes stay, so a list
without artwork shows the stock grey disc a little stretched).

## Mods

| Mod | Knob | Site | What |
|---|---|---|---|
| rowwave | `CDJ_MAIN_ROWWAVE` | after the list parser FUN_084C958C (call at 0x084EB2D6) | publishes the visible rows' track ids (table 0x081F0000) and points each row's artwork slot at our bitmap (0x081E0000 + (n-1)*0x1180) so the packer sends it instead of the JPEG |
| rowwaveb | `CDJ_MAIN_ROWWAVEB` | the parser's second call (0x084EBA64) | the same |
| rowcell | `CDJ_GUI_ROWCELL` | GUI pokes (0x0E51F32x, 0x0E59FF0x, 0x0E5A0FA8/C0) | the artwork cell becomes 112x20 (same 0x1180 bytes); icon, title and cursor move right |
| rowmeta | `CDJ_GUI_ROWMETA` | GUI literal 0x0E5208D0 (FUN_0e51e67a) + pokes `rowmetac` | the number column moves to the row's right end and shows the meta text MAIN writes after the title (slot text + 0x1A0); the cursor bar resource is copied, cropped to 634 px, to on-chip RAM |

The drawing itself is in `touch_audio` (`row_waves`): one export.pdb page
through the index built once per medium, the ANLZ `.EXT` PWV4 colour preview
(PWAV in blue when there is none) and the 20x20 artwork JPEG (decoded by the
`tadec` blob's stb_image; no artwork without it).

Enable all of it with the `rowwave` row of `mods/mods.conf`.

# Architecture

How Cueline sits inside the CDJ-2000NXS2 firmware. Addresses are NXS2 **MAIN 1.87** / **GUI 1.81** addresses (the
images our patcher targets) unless marked otherwise. The long reference is `docs/TECHNICAL_OVERVIEW.md`.

Evidence words used here: *deck* = seen on a real CDJ-2000NXS2; *emulator* = seen only in the maintainers'
emulator (not part of this repository); *unverified* = read in code or inferred, not exercised.

## 1. The three processors

| | MAIN | GUI | DSP |
|---|---|---|---|
| chip | Renesas SH7724, SH-4 | Renesas SH7269, SH-2A | TI C66x (C6655 per our notes) |
| byte order | little-endian | big-endian | little-endian |
| job | panel, media, database, Pro DJ Link, play engine control, UI model | draws the 800x480 screen (VDC4 display controller) | the audio pipeline |
| our code | most mods (`mods/*/main_*.s`), `mods/modsmenu`, `mods/keyshift`, `mods/player56`, `mods/tadec` | `mods/v2ui` (our renderer, C) and small `gui_*.s` mods | `mods/ownks/dsp` (Key Shift) |
| in the `.UPD` | section 3 (Motorola S-records around LZSS) | section 1 (LZSS) | inside MAIN: the DSP boot table |

The `.UPD` also has section 2 (DRIV) and section 4 (PANL, the panel microcontroller). We never change them;
`verify_update` checks they are byte-identical to stock.

MAIN executes in place from flash. The GUI is scatter-loaded: a load table copies segments from flash to RAM at boot.
Both are compiled with the same `sh4-linux-gnu` toolchain (`-ml` for MAIN, `-mb` and an SH-2A subset check for the GUI,
see `mods/v2ui/check_sh2a.py`).

## 2. MAIN <-> GUI: the SPI link

- Full-duplex SPI with DMA (MAIN MSIOF1, GUI RSPI1). Both sides exchange **4 KB frames** all the time.
- A frame carries messages: `[seq u8][type u8][len u16 BE]` + payload + 4 zero bytes + 4-byte checksum + `FF FF FF FF`.
  Long payloads continue in the next frames. Bulk payloads start with `[total u16][index u16]` (1-based).
- Main message types: 0x03 heartbeat (every frame), 0x39 UI model, 0x37 / 0x36 detail waveform (RGB / blue),
  0x35 / 0x34 overview, 0x2B beat grid, 0x32 markers, 0x05..0x16 image slots.
- The GUI dispatcher ignores unknown types. That is why we could add **message 0x31** (`mods/w8fetch`): the tempo
  master's waveform and grid, the loaded track's cue block and its artwork. See `docs/TECHNICAL_OVERVIEW.md` §4.3.
- MAIN receives into a ring of 3 RX slots (0xA9072B38 + slot << 14); TX is the 4th slot (0xA907EB38).
- **GUI -> MAIN:** one word in the GUI's TX frame at +0xFF0: `"KY" << 16 | valid << 7 | (shift + 12)`, the KEY SYNC
  target. MAIN reads it every 128 ms.

### 2.1 The heartbeat and the publish words

The heartbeat block is MAIN 0x0B568C9C (0x1A8 bytes); the GUI sees it at **0xFFF88000** (wire offsets are 4 more).
Stock leaves some words free. We fill them just before each copy of the block (modsmenu `mm_copy`, redirected from
the two heartbeat-copy literals 0x08390944 / 0x08391B60).

| offset | owner | content |
|---|---|---|
| +0x14 | modsmenu | publish word 2 (magic 5). Two pages (bit 28). Page 0: SCREEN MODE, master key code, pressed row. Page 1: KEY SHIFT state, TEST LOG mode (DEV), HOT CUE COLOR, own player number, own SD / USB mounted, sixth zoom, KEY FORMAT |
| +0x18 | modsmenu `sl_pub` | while SLIP is on: `'S' << 24` + slip position in ms (slip ghost). Otherwise the `'K'` word: MASTER WAVEFORM, HW BAND LAYER, WAVEFORM HALF |
| +0x54 | modsmenu | publish word 1 (magic 0x4C): LIGHT MODE, BPM DECIMALS, WAVEFORM COLOR, POSITION, phase-meter style, LINK master slots |
| +0xE8 | modsmenu | publish word 3 (magic 7 in bits 29-31) |
| +0x1E0..+0x1EC | modsmenu | browse state words (list page, rows loaded elsewhere, preview row, UTILITY category) |

Stock words we read include the player number (+0x58 / +0x5C), tempo and position (+0x64, +0x70 / +0x78), beat counter
(+0x84), tempo master (+0xA4), SLIP (+0xDC) and A.HOT CUE (+0x15F / +0x163 / +0x167). Full table:
`docs/TECHNICAL_OVERVIEW.md` §4.2.

### 2.2 Models the GUI reads

MAIN's models arrive in GUI RAM by DMA, so `v2.c` reads them through the **uncached mirror** (+0x20000000).

| model | GUI address |
|---|---|
| UI model (0x39) | 0x0E5B829C |
| heartbeat | 0xFFF88000 |
| overview records (600 x 6 B) | 0x0E5B748C |
| detail length (0 = no analysis) | 0x0E5BC26C |
| markers (0x32) | 0x0E604F10 |
| update state (3 = update mode) | 0x0E5B6B40 |

## 3. How mods are placed and linked

The patch engine is `mods/sigpatch.py`, shared by `mods/patch_main.py` (MAIN) and `mods/patch_gui.py` (GUI).

### 3.1 Signatures, not addresses

A mod names the code it replaces by a **signature**: the halfwords around the site, plus the span to replace.
A PC-relative `mov.l @(disp,pc)` matches on opcode and register only, so a signature survives small code moves.
All values are logical; `ImageProfile.byteorder` (`<` MAIN, `>` GUI) does the byte swapping. Each mod also lists the
firmware versions its signatures were checked against (`fw_versions`); the tool refuses others.

### 3.2 Two placement shapes

- **GUI (scatter-load):** the routine goes into erased flash after the loaded segments, and a new load-table record
  copies it to RAM at boot. Small `gui_*.s` mods share one segment at 0x1C04B000; the `v2ui` renderer gets its own
  record (code at 0x1C050000, read-only data copied to SDRAM 0x0C700000).
- **MAIN (execute in place):** the routine is written into a run of erased flash inside the layout's code range.
  That address is both storage and execution address.

### 3.3 Hooks, replacements, literal redirection, pokes

- `hook=False`: the routine replaces the span and repeats the stock instructions itself.
- `hook=True`: several mods share one site. The span moves into a trampoline that runs it once, then calls every
  selected hook in registry order (`sigpatch.trampoline()`). Hooks may clobber r0-r7 only.
- **Literal-pointer redirection** (the most common MAIN hook). Many stock calls load their target from a literal pool
  (`mov.l @(disp,pc),rN; jsr @rN`). We rewrite only that literal to point at our routine, which then tail-calls the
  stock target. The patcher checks the literal still holds the expected stock value before writing.
  `sigpatch.literal_pool_reads()` decodes every PC-relative load of the image, so we know no stock code reads from
  space we claim.
- **Pokes** (`patch_main.MAIN_POKES`): single halfwords changed in place, each checked against stock. No hook, no
  spawn, no malloc.
- **MAIN mods are assembled and objcopied, not linked.** Never use `.long own_label`; use `mova` or PC-relative
  addressing.

### 3.4 FIXED blobs

Some pieces are linked at a fixed address instead of being bump-placed (`patch_main.FIXED`):

| name | address (`ks` layout) | what |
|---|---|---|
| `modsmenu` | 0x08014000 | UTILITY items, touch layer, publish words, build record, kill words (`mods/modsmenu/modsmenu.s`) |
| `tadec` | 0x08018000 (256 KB arena) | MP3 / FLAC / JPEG decoder blob for Link Cue and artwork (`mods/tadec`) |
| `keyshift` | 0x08123000 (KSB) | KEY SHIFT front end and KEY SYNC (`mods/keyshift/main_keyshift.s`) |
| `ownks` | 0x08122000 (state 0x08122800) | our Key Shift engine, MAIN side (`mods/ownks/main_ownks.s`) |
| players 5/6 | 0x081C4000 (16 KB) | `mods/player56` cave (announce stub 0x081C7F00) |
| `reclaim` | in place | frees the non-Latin text code pages (`mods/reclaim/reclaim.py`) |

### 3.5 Layouts and the MAIN memory map

`patch_main.LAYOUTS`; `layout_for()` picks `ks` whenever `keyshift` is in the mod list.

| layout | our routines | modsmenu | lang block | tadec | RAMB |
|---|---|---|---|---|---|
| `stock` (no Key Shift) | 0x0811AF80-0x08140000 | 0x0813B000 | 0x0813FF00 | 0x08140000 (256 KB arena in a no-Key-Shift build) | 0x081E0000 |
| **`ks`** (the release recipe) | 0x08003500-0x08014000 | 0x08014000 | 0x08017C00 | 0x08018000 (256 KB arena) | 0x081E0000 |

The `ks` layout exists because the Key Shift engine moves the DSP boot table from 0x080034E0-0x08091238 to
0x08130000 (slot up to 0x081C22C8). The freed area holds our routines.

`ks` memory map (MAIN flash addresses = execution addresses):

| range | what |
|---|---|
| 0x08003500-0x08014000 | sigpatch-placed routines (all mods) |
| 0x08014000 | modsmenu block: +0xF0 MODS / LINK CUE / WAV 32-BIT words, +0x180 **build record** (BLDID 0x08014180), +0x1E0 **kill words** (KILLB 0x080141E0), then the UTILITY item table |
| 0x08017C00 | lang2 block (<= 0x100 B) |
| 0x08018000 | tadec blob |
| 0x08122000 / 0x08122800 | Key Shift engine routine / state |
| 0x08123000 | KSB: Key Shift front end (+48 KEY SYNC on, +64 refusal tick, +100 LINK KEY STATUS) |
| 0x08130000-0x081C22C8 | DSP boot table slot |
| 0x081C4000 | players 5/6 cave |
| 0x081E0000 | RAMB (128 KB run-time data) |

### 3.6 RAMB

RAMB is a 128 KB data area at 0x081E0000. It is erased (0xFF) at boot and written at run time. Each user zeroes and
stamps its own block on first use. Shared offsets are in `mods/layout.inc`.

| offset | owner | content |
|---|---|---|
| +0x10000 | rowwave | browse row ids and mini waveforms (`RWV3`) |
| +0x14000 | touch_audio -> w8send | cue block (`PCO2` + the track's cue tags, `TITL` at +0xF80) |
| +0x15010 / +0x15030 / +0x15100 | touch_audio | cue block control / artwork control / artwork block (`PART`) |
| +0x1E000 | w8fetch | W8 state, 128 B (`w8fetch/w8.inc`) |
| +0x1E800 | ks3k | CDJ-3000 status key per player, 8 B each |
| +0x1F700 | touch_audio | medium state |
| +0x1F7E8 | modsmenu / TchAud | kill word (`NOMO`) |

Rule: a new user takes a free offset, documents it here and in `mods/layout.inc`, and zeroes it on first use.

## 4. GUI: our renderer and the VDC4 layers

- `mods/v2ui/v2.c` is our renderer. `v2_paint(plane, base)` runs just before the stock VDC base write 0x0E526626, when
  a finished frame is handed to the display controller but is not yet on the panel. The two stock literals that call
  0x0E526626 are redirected to our entry (`mods/v2ui/v2ui.py`).
- We draw the player, the browse family, INFO, UTILITY, SHORT CUT, player INFO and the pop-ups; `screen_mode()` in
  `v2.c` decides per frame (modes `M_PLAYER`, `M_BROWSE`, `M_SHORTCUT`, `M_PINFO`, or `M_NONE` = stock). Stock still
  draws **boot and the update screen**; we draw nothing while the GUI update state is set.
- **SMOOTH present mode** (default): we compose into an off-screen canvas at 0x0CC00000 (800x480 RGB565) and copy only
  the dirty 16-row bands into the GR3 buffer after the latch. Region-by-region painting into the live buffer tore on
  the real panel (deck), never in the emulator.
- **Stock overlays** (status line, banners) are re-blitted into our layout and hashed, so only changed regions repaint.

### 4.1 The waveform band on GR2, GR3 chroma key (`mods/v2ui/hwband.inc`)

- The detail waveform lives on the **VDC4 graphics layer GR2**: window x 16..783, y 122..305, RGB565, line offset
  3584 B.
- Two **rings of 896 columns** (128 more than the window), every column stored twice (slots s and s + 896). Ring A
  0x0CB38000, ring B 0x0CA94000, each 0xA1000 B, written uncached. New columns always land in slots the panel is not
  scanning, so there is no tearing.
- Waveform, beat ticks, cue marks, loop shading are baked into the ring per column.
- On **GR3** (the normal frame buffer) the band area is filled with the **chroma-key colour 0x0001**, so GR2 shows
  through. Fixed overlays (playhead, pads, labels) sit on GR3 and redraw only when their inputs change.
- **Scrolling:** the real VDC4 ignores the fine start-position register (deck). We keep the base 4-px aligned and move
  the GR2 window left by the remainder (0..3 px). Both registers are committed in the same frame. Result: 1-px steps
  at 60 fps (deck).
- A zoom or look change rebuilds the **hidden** ring on a time budget while the shown ring keeps scrolling, then flips
  at one vsync.
- The band is live only on our player screen with an analysed track and no pop-up. Every other frame falls back to the
  software band in the same frame. Kill switch: UTILITY > INFO > HW BAND LAYER.

Rule (from the project): use the hardware (VDC4 layers, DMA, the JPU) before adding CPU redraws.

### 4.2 GUI room

The patched GUI section must be **at or below the stock size**. Room comes from `lang2` (English and Spanish only),
`guitrim_cjk` (Chinese and Korean glyph banks zeroed) and trimmed glyph sets (`CDJ_V2_FONTTRIM`). The build log prints
the GUI section size; compare it with stock (6,931,940 B).

## 5. DSP: the boot table and our Key Shift engine

### 5.1 The DSP boot table

The DSP program is not in its own `.UPD` section. It is a **boot table** of sections inside MAIN flash (stock:
0x080034E0-0x08091238). At boot, a MAIN loader streams it to the DSP in 16 KB windows (loader constants at
0x08326692, 0x0832669C / 0x083266A4, pointer / length at 0x0832691C / 0x08326920) and computes the checksum itself.

MAIN talks to the running DSP with requests. Two matter here (from our own record / replay analysis, emulator):

- type 5 carries the tempo block; its first rate word is the only one the DSP uses for tempo and MASTER TEMPO;
- type 10 "write words" writes N words at the DSP parameter block 0x008C8800 + id. Our engine uses it to set its
  pitch factor.

There is no parameter that separates stretch from pitch inside the stock MASTER TEMPO engine, so Key Shift is a
separate stage.

### 5.2 Our Key Shift engine (`mods/ownks`)

- **DSP side** (`mods/ownks/dsp/ownks.c`, C, about 3.7 KB): a new boot-table section at DSP 0x805C0000 (a DDR range
  the stock program never touches). The L2 trampoline at 0x0080DD50, through which the audio transmit interrupt calls
  the deck's audio pipeline, is retargeted to `ks_fill`. `ks_fill` calls the stock pipeline, then pitch-shifts the
  finished block in place.
- **Algorithm:** two read taps on a 4096-frame ring, half a window apart (window 2048 frames, about 46 ms), with
  sin^2 / cos^2 crossfade weights and linear interpolation. Samples in = samples out, so tempo never changes.
  Factor 1.0 crossfades to the dry signal and then bypasses bit-exactly.
- **Semantics** follow from post-processing: MASTER TEMPO on -> key = original + shift; MT off -> key = original +
  fader + shift.
- **Loading:** `mods/ownks/ownks.py` checks the 16 stock sections by sha256, appends ours, places the table at
  0x08130000, erases the old area and rewrites the loader constants. No runtime code writes.
- **MAIN side** (`mods/ownks/main_ownks.s`, at 0x08122000): `oks_dj` runs the stock DJcont output step, then sends the
  factor 2^(k/12) as float bits with the stock "write words" request, on every change and every 256 calls. State
  block 0x08122800: +0 on, +4 semitones (-12..+12), +16 generation.
- **Front end** (`mods/keyshift`, modsmenu items, the v2ui panel) drives that state block. The DJcont literal
  0x082D8970 points at the front end's gate `ks_dj`, which calls `oks_dj` only on a normal boot.
- **Status:** pitch measured exact in the emulator (+2 / +7 / -5 semitones, tempo unchanged); about 23 ms average
  added latency while shifted. **Not yet confirmed on a real deck** (audibility, DSP load).

## 6. KEY SYNC and the 3000-format status packet

Network protocol facts only (Pro DJ Link status packet, type 0x0a, UDP 50002).

- A CDJ-3000 status packet is 0x480 bytes; the NXS2's is 0x124. The key fields used for KEY SYNC:

  | offset | field |
  |---|---|
  | 0x154 | original key: {b0 tonic of the relative major 0..11, b1 mode, b2 spelling -1 / 0 / +1, b3 valid} |
  | 0x158 | MASTER TEMPO flag (byte) |
  | 0x15C | sounding key, same form |
  | 0x160 | sounding cents, int32 BE |
  | 0x164 / 0x168 | KEY SHIFT in cents (we send int64 BE at 0x164; we read cents at 0x168) |
  | 0x16C | shift-valid flag (1) |

- Camelot number = (b0 * 7 + 8) mod 12 (0 -> 12).
- **Receive** (`ks3k`, hook on the status receive): the stock table keeps only 0x124 bytes, so the extra key is kept at
  RAMB + 0x1E800 + player * 8.
- **Send** (`kx_send` in `mods/keyshift`): while LINK KEY STATUS is on, our status goes out as 0x180 bytes with these
  fields filled. Stock NXS2s copy only 0x124 bytes and are unaffected.
- **KEY SYNC** itself: the GUI computes the target shift (nearest of M, M+1, M-1 in Camelot with |shift| <= 2),
  publishes it in TX +0xFF0, and MAIN applies it, turning MASTER TEMPO on.
- **Status:** checked with synthetic 3000-format packets and on a test segment; **not yet confirmed with a real
  CDJ-3000**.

## 7. Update-mode safety

- Boot words at 0x0A35DF30: **+0xC (0x0A35DF3C) = 1 normal boot, 2 update mode**; +0x10 = update kind (1 = USB).
- In update mode the stock updater deletes the normal heap and builds its own in the same memory. The `.UPD` buffer
  lands there. Anything of ours that allocates or runs a task at that time can be overwritten by the file read, or
  overwrite it.
- This happened: an early Link Cue task spawn had no guard. With a slow stick the task started first, the file read
  overwrote its stack and MAIN reset. On the deck it looked like "this build will not install".
- **Rule:** no MAIN mod counts, allocates, spawns or hooks unless `*0x0A35DF3C == 1`. Literal-redirect stubs test it
  on every call. Pokes in load-time code never run in update mode and need no gate.
- The GUI side: stock draws the update screen; `v2.c` returns `M_NONE` while the GUI update state is set.
- The UTILITY item count stored in the image hides our extra rows; they are revealed only after a normal boot.
- A MAIN update also rewrites the boot and emergency area (0x0-0x4FFFF) with the stock bytes from the same `.UPD`; the
  GUI bootloader is never in a `.UPD` (section header byte 31 = '0'). Keep the window short: small stick, UPS.
- Every candidate goes through the racegate (see `docs/dev/TESTING.md`).

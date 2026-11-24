# Cueline -- technical overview (custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000)

Authors: the cdj-nxs2-3000ui project. Written for the CDJ-2000NXS2 modding community with our source package.
Date: 2026-11-16 (V4 release; RC1 = V4n24 was 2026-11-13). Base firmware: official CDJ-2000NXS2 **MAIN 1.87**
(SH-4, SH7724, little-endian) and **GUI 1.81** (SH-2A, SH7269, big-endian). This is a personal, non-commercial
project.

Most of our working notes are in Spanish or are terse build logs and are not shipped. This document collects them
in English, together with the header comments of the files under `mods/` (the primary source for every detail).
Where a section names a note file (`re/...`), that note is internal; the facts are summarised here. Sections 0,
1.2, 4.2, 5.2, 10, 11, 12 and Appendix A are updated for the V4 release; §12 describes everything added after RC1.

### Evidence tags used below

| tag | meaning |
|---|---|
| **[deck]** | Seen on the real CDJ-2000NXS2. |
| **[emu]** | Seen in our QEMU emulator of both CPUs only. |
| **[link-emu]** | Seen on our bridged Pro DJ Link test segment: our emulated NXS2, a stock 1.87 emulator, a CDJ-3000 emulator and (sometimes) the real deck. No real CDJ-3000 was involved. |
| **[static]** | Read in code; not exercised. |
| **[open]** | Unknown or not yet verified. |

Addresses are MAIN 1.87 / GUI 1.81 addresses unless noted. This document has no firmware bytes, no
disassembly and no keys.

---

## 0. The V4 release at a glance

| item | RELEASE | DEV |
|---|---|---|
| Tag / build ID | `Cueline-2.3.1 20261124-1809 49e8943c` | `R23U1n 20261124-1811 49e8943c` |
| UPD sha256 | `65c30bdef959704e86460b996b5c2ec3f1add7b10fb677e5bcbbedbe6f6e0914` | `a63b7cbe8daeaa8a18dac970ec4cf7a6ae058ccc7c7a40d009f0d75d7310ab4f` |
| Labels | `MAINVer2.30` / `GUI Ver2.24` (bump 43) | `MAINVer2.30` / `GUI Ver2.24` (bump 43) |
| MAIN | section 9,347,916 B; packed 3547840 of 3846144 B 92.2%; layout `ks` | packed 3553375 of 3846144 B 92.4% |
| GUI | section -> B (stock 6,931,940 B) | -> B |
| GUI flags | `-DV2_DMACPY -DV2_VSPACE -DV2_BDIRECT -DV2_AUTO60 -DV2_HWBAND -DV2_KEYSHIFT -DV2_MSUB -DV2_G3PURGE -DV2_GR1METER -DV2_SC0BYP` | `-DV2_HUD -DV2_DMACPY -DV2_VSPACE -DV2_BDIRECT -DV2_AUTO60 -DV2_HWBAND -DV2_KEYSHIFT -DV2_MSUB -DV2_G3PURGE -DV2_GR1METER -DV2_SC0BYP -DV2_USBLOG` |
| MAIN mods | touchaudio touchaudioip touchaudiotouch tadec modsmenu wav32 rowwave three_band ui3000x bootname font3000 v2ui v2needle lang7 usbkey keyshift reclaim guitrim_cjk w8send w8cap w8recv ks3k ownks jogcue link0brx link0btx + player56 (`proven`) | + autotest usblog |
| UTILITY items | 42 | 43 (+ TEST LOG) |
| Gates | verify PASS, `gui_bootcheck --strict` PASS, racegate R1 + OFF: 0 MACHINE RESET | same |

Both are built by `build.sh` (`PROFILE=release|dev`) from the same sources (source hash `49e8943c` = sha256 of
every `mods/` source, `patch_main.source_hash()`); `CDJ_PROFILE=release` makes `build_final` / `patch_main`
refuse the dev flags and mods.

---

## 1. Architecture

### 1.1 MAIN (SH-4): the signature patcher and literal redirection

`mods/sigpatch.py` is the patch engine that `patch_main.py` (MAIN) and `patch_gui.py` (GUI) share.

- **Sites are found by signature, not by address.** A mod gives the halfwords around the code it replaces
  (`sig`, with `start:end` as the span to replace). A `mov.l @(disp,pc)` matches on opcode and register only,
  so a signature survives code moves. Every halfword and word is handled as a logical value through the
  image's byte order (`ImageProfile.byteorder`: `<` for MAIN, `>` for the GUI).
- **Two placement shapes.**
  - *Scatter-load* (GUI): the routine goes into erased flash after the on-chip RAM segments, and one new
    load-table record copies it out.
  - *Executed in place* (MAIN): the routine is written into a run of erased flash inside the profile's
    `ram_base..ram_end`. That location is both its storage and its execution address.
- **Hooks versus replacements.**
  - With `hook=False` the routine replaces the span and repeats it itself.
  - With `hook=True` several mods share one site. The span moves into a trampoline, which runs it once
    and then calls each selected hook in registry order (`sigpatch.trampoline()`). Routines may clobber
    r0-r7 only.
- **Literal-pointer redirection.** This is the most common MAIN hook. Many stock calls go through a
  constant in a literal pool (`mov.l @(disp,pc),rN; jsr @rN`), so we rewrite only that literal so it
  points at our routine. Our routine then tail-calls the stock target.
  - `patch_main.py` checks that every literal still holds the expected stock target before it writes.
  - `sigpatch.literal_pool_reads()` decodes every PC-relative load in the image, so we know no stock code
    reads from the space we claim.

Examples in RC1 (all checked against their stock value at build time):

| literal | stock target | ours |
|---|---|---|
| 0x0844E240 / 0x0844E488 | touch_event 0x084ECCF8 | modsmenu `v3e_touch` (3000 tap targets, drag) |
| 0x0844F1C8 | knob delta 0x084D2210 | modsmenu letter jump / knob hook |
| 0x0846D990 / 0x0846D5D0 / 0x0846D5D4 | settings unpack / pack / HISTORY-record memset | modsmenu `mods_load` / `mods_save` / `hist_save` |
| 0x08390944, 0x08391B60 | heartbeat block copy 0x085336DC | modsmenu `mm_copy` (publish words, §4.2) |
| 0x082D8970 | DJcont DSP-output step 0x082DBC2E | keyshift boot gate `ks_dj`, which then calls the Key Shift engine (keyshift builds only) |
| 0x0844DAC8 / 0x0844E1EC | MASTER TEMPO setter 0x084E171C | keyshift `mt_set` (KEY SYNC turns MT on) |
| 0x0844D7AC / 0x0844DEF8 | hot-cue setter 0x084E1974 | keyshift `hc_set` (KEY SYNC BUTTON on pad D/H) |
| 0x0844FF7C | pad-RGB getter 0x084DC684 | keyshift `hc_lamp` |
| 0x0844FA40 / 0x0844FA44 | jog-ring level getters 0x084DC640 / 0x084DC64A | jogtest (probe, TEST) |
| 0x08450414 | slip-active 0x0843E344 (inside the jog tx builder) | jogcue |
| 0x083D6CF8 | JpegMgrTask free path | `jm_shim` (artwork decode through the JPU, §6) |
| 0x084DCBE8 | USB-key lamp predicate | usbkey (steady USB lamp once mounted) |
| 0x0844D730 / 0x0844E23C | debug-key literal / touch calibration | autotest (TEST) |

A few stock behaviours are changed by **in-place pokes** (`patch_main.MAIN_POKES`). For example, `rgbdetail`
at 0x0849EB54 always requests the RGB (PWV5) detail first, whatever the stick's stored WAVEFORM COLOR is.
`rowgraypack` keeps the loaded browse row coloured. Pokes are single halfwords in load-time code. They have no
hook, spawn or malloc, so they never run in update mode.

**One lesson.** MAIN mods are assembled and objcopied, not linked. Never use `.long own_label`; use
`mova` / PC-relative addressing instead. One stray absolute label once broke the TchAud task.

### 1.2 MAIN space: layouts, caves, flash budget

`patch_main.LAYOUTS`; `layout_for()` picks `ks` whenever `keyshift` is named on a stock base.

| layout | our routines | modsmenu | lang block | tadec | RAMB |
|---|---|---|---|---|---|
| `stock` (no keyshift) | 0x0811AF80-0x08140000 | 0x0813B000 (package overlay; was 0x0813E000) | 0x0813FF00 | 0x08140000 | 0x081E0000 |
| **`ks` (V4)** | **0x08003500-0x08014000** | **0x08014000** (block + UTILITY table up to 0x08017C00) | **0x08017C00** (V4n37h; was 0x08017000) | **0x08018000** (256 KB arena, ends 0x08080190) | **0x081E0000** |

How the `ks` layout is built:

- The Key Shift engine moves the DSP boot table from 0x080034E0-0x08091238 to 0x08130000-0x081C22C8; the `ks`
  layout reuses the freed area for our code. A build without keyshift uses the `stock` layout (tadec at
  0x08140000 with a 256 KB arena, below the players 5/6 cave).
- In RC1 the sigpatch segment was 50,432 B at 0x08003500 (at V4n37: RELEASE reserves about 36 KB of routines,
  DEV about 57 KB). The modsmenu block at 0x08014000 holds the build record (+0x180 = **0x08014180**), the kill words
  (+0x1E0 = **0x080141E0**) and the UTILITY item table, which ended at 0x08016BC0 (RELEASE, 42 items) /
  0x08016C90 (DEV, 43) at V4n37. It outgrew the old lang2 address, so V4n37h moved the lang2 block (<= 0x100 B) to
  **0x08017C00**, right under tadec at 0x08018000 (~3 KB free).
- Our Key Shift front end (KSB) sits at **0x08123000** in keyshift builds.
- The players 5/6 cave is at **0x081C4000** (16 KB), above the end of the DSP table.
- `reclaim` frees about 96 KB packed. It maps every language to the cp1252 path (languages 7..18), erases
  the non-Latin tables (0x08101B00-0x08118700) and stubs their converters (0x084F151C-0x084F29D0).
  Every byte is compared with stock before it is written. The MAIN UI is EN/ES-only anyway (§2.8).

**RAMB** is a 128 KB data area at 0x081E0000. It is erased (0xFF) at boot and written at run time. Each user
zeroes its own block on first use (for example, w8send stamps `W8F1`).

| RAMB offset | owner | content |
|---|---|---|
| +0x10000 | rowwave | browse row ids / waves, magic `RWV3` |
| +0x14000 | touch_audio -> w8send | cue block: `PCO2` header + the track's PCO2 tags; `TITL` record at +0xF80 |
| +0x15010 | touch_audio | cue block control (seq, sent, total, key, rbid, state) |
| +0x15030 / +0x15100 | touch_audio | loaded-track artwork control / block (`PART`) |
| +0x1E000 | w8fetch | W8 state, 128 B (`w8.inc`) |
| +0x1E800 | ks3k | CDJ-3000 status key per player, 8 B each |
| +0x1F700 | touch_audio | medium state (`MED`) |
| +0x1F7E8 | modsmenu / TchAud | kill word (`NOMO`) |
| (malloc) | bbox | BLACK BOX ring, 8,832 B, malloc'd once inside the boot gate (§12.9) |

**Flash budget** (`re/MAIN_BUDGET_AUDIT.md`, memory notes):

- The real limit is the *packed* MAIN size, about 3,846,656 B packed;
  `patch_update` uses 3,846,144. R23U1r packs 3547840 of 3846144 B 92.2%, R23U1n 3553375 of 3846144 B 92.4%.
- An earlier "MAIN section limit" of 0x902A00 was a misdiagnosis. Its real cause was the update race in §1.3.
- The T1 deck test proved a 9.48 MB section installs. RC1 is built with
  `--no-main-size-check`.

### 1.3 Update safety: the boot-state gate and the racegate

**The rule.** No MAIN mod may count, malloc, spawn or hook unless **`*0x0A35DF3C == 1`**, which means normal
boot.

- The boot words are at 0x0A35DF30. `+0xC` is 1 for normal boot and 2 for update mode. `+0x10` is the update
  kind (1 = USB).
- In update mode every one of our entry points takes the exact stock path. Literal-redirected stubs test the
  word on **every call**, not once.

**Root cause (re/T1_RESCUE2.md, V3rc3 §0).**

1. In update mode the stock updater deletes the normal heap (del_mpl at 0x084F2E2A) and builds `UpDate_mpl`
   in the same memory. The .UPD buffer lands around 0x0BFDB1C4.
2. Our older touch_audio spawn hook (on the DJCONT_PASS path) had no update-mode guard. After about 1000
   passes (~4 s) it malloc'd the TchAud task (~28 KB) from that heap.
3. When the stick mounted slowly (large sticks), the task started first. The file read then overwrote the
   task's live stack, which produced a garbage label and a MAIN reset.
4. This looked random because it depended on stick speed. On the deck it showed up as "this build will not
   install" and as builds being skipped.
5. Rescue that worked on the deck: a small FAT32 stick holding only a MAIN-only official 1.87 file.

**The racegate** (`racegate.sh TAG`, internal emulator tooling, not shipped) is permanent and runs on every build staged for the deck:

1. It makes a variant of the build with touch_audio's spawn threshold forced from 1000 to 100. That forces
   the bad order (spawn before the updater deletes the heap).
2. In the emulator it runs update mode twice: with R1 (a MAIN-only label-2.30 rescue file) and with the
   official 1.87 `.UPD`.
3. PASS means: no MACHINE RESET, TchAud never spawned, and the updater reaches its file states (state word
   0x0B56A3E0, state 6).

### 1.4 The .UPD pipeline

**`mods/patch_update.py`** takes the user's own `C2KNXS2.UPD`:

1. Split the CRLF-decimal manifest and its sections.
2. Decode the GUI section (LZSS) and the MAIN section (Motorola S-records wrapping the same LZSS).
3. Apply every named mod per image in one `patch()` call, so all mods share one placement.
4. Apply the container-level pseudo-mods: `lang2`, `font3000`, `v2ui`, `v2needle`, `guitrim*`.
5. Re-encode, then fix lengths, checksums and the GUI image trailer (CRC-16 at 0x14FFFA over [0:end]).
6. Rewrite the manifest.

Every mod declares the firmware versions its signatures were verified against, and the tool refuses a
mismatch.

**Versions and labels.** The updater (MAIN 0x084F30B8) reads the section label's `VerX.YY` and compares it with
the installed version. It writes MAIN and GUI only when the label is **newer**.

| finding | evidence |
|---|---|
| A `+` in the installed string does not let an equal label in. Only "label newer than the installed label" counts. | [deck] |
| Every deck build therefore takes `--main-bump=N --gui-bump=M`. RC1 is MAIN 3.29 / GUI 3.28. | build log |
| The images keep their internal version string ("1.87+" in MAIN). The deck announces that string on Pro DJ Link; a "1.88" there made stock decks warn "older firmware". | [deck] |
| Rollback: a factory reset (DUPLICATION -> DEFAULT) clears the installed label, then the official 1.87 writes. The result is byte-identical stock; only the settings log keeps residue. | [deck] |
| A MAIN update also reprograms the boot and emergency area 0x0-0x4FFFF. The GUI bootloader is never in a .UPD (section byte 31 = '0'). | memory notes |

**`scripts/firmware/verify_update.py`** re-reads the candidate the way the updater would:

- The container and labels are correct.
- Every CRC-16/XMODEM trailer, every S-record checksum, and MAIN's 16-bit byte sum (which the bootloader
  checks) are correct.
- DRIV and PANL are byte-identical to stock. In MAIN, every S-record below the application (bootloader and
  emergency updater) and the S7 record are identical to stock.
- The decoded images equal what `patch_gui` / `patch_main` produce for the same mod names (that is, what
  the emulator ran).
- The packed MAIN fits.

**`scripts/firmware/gui_bootcheck.py --strict`** is a static model of what the GUI bootloader needs:

- Section header, with byte 31 = '0' ('1' would erase the bootloader).
- Section CRC.
- Stream and decoded lengths.
- The scatter-load descriptor chain: copies inside the image, destinations in real RAM, no overlapping
  copies, and the entry point inside a copied segment.
- The image trailer CRC.
- Artwork and font archives decode and fit their windows.

We have never had the GUI bootloader's bytes, so this check is inferred from the GUI's own update and flash
tasks.

`patch_main.assemble()` (`--assemble`) must run before a build. Committed `.bin` blobs once went stale against
their `.s`, and `patch_update.check_committed_bins` now guards against that.

### 1.5 GUI (SH-2A): our own renderer `mods/v2ui/v2.c`

- **Placement (RC1).**
  - The code blob is 88,264 B at 0x1C050000 (flash load record 5).
  - The read-only data, 112,624 B, is copied by the renderer to SDRAM 0x0C700000.
  - Small patch_gui routines use 2,432 B at 0x1C04B000 (load record 4).
- **Entry.**
  - The two stock VDC base-write literals are redirected to our entry.
  - `v2_paint(plane, base)` runs just before the stock VDC base write (0x0E526626), when a finished frame is
    handed to the VDC but is not yet on the panel.
  - A few other stock call literals are chained through our table, each calling the stock target afterwards.
- **Screens we own.** We draw the player, browse family, INFO, UTILITY, SHORT CUT, player INFO and the
  pop-ups. Stock still draws boot and the **update screen**. That is a hard rule: the installed GUI draws
  update mode, and a GUI timing poke once broke update mode on the deck.
- **Reading MAIN's models.** We read through the uncached mirror (+0x20000000) because the models are
  DMA-filled.

  | model | GUI address |
  |---|---|
  | UI model 0x39 | 0x0E5B829C |
  | heartbeat copy | 0xFFF88000 |
  | overview records | 0x0E5B748C |
  | detail length | 0x0E5BC26C |
  | marker model 0x32 | 0x0E604F10 |
  | big artwork slot | 0x0E619170 |
  | update state | 0x0E5B6B40 (3 = update mode) |

- **Present modes (V3rc4, [deck]).** On the real panel, region-by-region painting into the buffer about to
  latch caused periodic tearing that the emulator never showed.
  - **SMOOTH** (default) composes off-screen into a 768,000 B canvas at **0x0CC00000**, then copies the dirty
    16-row bands into the GR3 buffer after the latch.
  - FAST (per-region) and SMOOTH+ (time-smoothed band position) can be picked from a SHORT CUT tile. The
    choice is not saved.
  - This fixed the flicker on the deck.
- **Stock overlays.** `ovl_blit` re-blits stock windows (status line, banners) into our layout. Since V4f it
  hashes their pixels and resets only the regions they touch. The stock "NO DISC" line once forced a
  480-row repaint every frame (24 fps on the deck).
- **GUI room.** Our rule is that the GUI section must stay at or below stock size. Earlier V4 builds had
  between 7 B and 600 B left. `guitrim_cjk` (zeroes the CJK glyph banks, a cosmetic effect only) gives about
  2.9 MB of room, and RC1 is about 2.94 MB under stock.
- **Build flags (V4).** RELEASE `-DV2_DMACPY -DV2_VSPACE -DV2_BDIRECT -DV2_AUTO60 -DV2_HWBAND -DV2_KEYSHIFT`; DEV adds
  `-DV2_HUD -DV2_USBLOG`; both with `CDJ_V2_FONTTRIM=1`. GUI room: R23U1r is ? MB under stock.
- **Icons.** Our own icon set in the 3000 style (shipped as sources) plus stock NXS2 icons taken from the
  builder's official 1.87 `.UPD` at build time; the generated atlas is not shipped. No other firmware is needed.

---

## 2. The UI (CDJ-3000 layouts on 800x480)

Design rule (user): copy the CDJ-3000 and adapt only what the NXS2 hardware cannot do. The references are the
CDJ-3000's behaviour and look (a CDJ-3000 emulator, screenshots and camera video).

### 2.1 Player
- **Header:** source tile, title, (i), key, artwork 35x38 (§6), track length sub-line, tiles for LOOP MODE,
  BEAT JUMP, PREVIEW and KEY SHIFT. The player number blinks while it is being negotiated and turns grey when
  it is not confirmed (heartbeat +0x58 == 0, §4.2).
- **Band:** detail waveform (§3), red playhead (white when paused, yellow in SLIP).
- **Pads under the band:**
  - BEAT LOOP pads use a #191919/#323232 checker with a #FF7323 frame; lit pads are #FF7323/#E15A0F.
  - BEAT JUMP pads use a checker.
  - The KEY SHIFT panel replaces the pad row while it is open.
- **Right column:** BPM box with a MASTER tab and BEAT SYNC; tempo % and range chips; MT; KEY box.
- **KEY box:**
  - Green when the key is harmonic with the master.
  - The **sounding key in grey** when MT is off and the fader moves the key (as on the 3000).
  - Orange for a shifted key.
- **A.HOT CUE indicator:** red ON, white rekordbox SETTING, hidden OFF (heartbeat +0x15F/+0x163/+0x167).
- **Phase meter:** a tap cycles PHASE (3000 bars) -> WAVEFORM (the master's waveform, §5.1) -> 4 BARS (NXS2
  classic). The choice is saved.
- **Overview:** moved 12 px up to the 3000 position, time labels fully visible, hot-cue badges, memory-cue
  triangles, cue comments (§7).
- **No analysis:** a track without rekordbox analysis shows nothing derived from analysis (no band, overview,
  grid or ticks), as on the 3000.

### 2.2 Browse
- **Layout:** a 56-px left icon rail, a header (back, list title, PREVIEW tile, `< INFO`), column headers,
  8 rows of 40 px from y 90, and a thin deck strip at y 420..479.
- **Track row:**
  - PREVIEW cell with a mini-wave. RC1 uses a fixed 86 columns. Per V4n21 it is a **bottom-anchored stack**
    like the 3000's 3BAND browse (low blue, mid orange, high white), height h*20/31, not mirrored.
  - **Artwork thumbnail** 20x20 (§6), title, BPM, KEY.
- **KEY column:** compatible keys (own, ±1, relative) get a **green cell background with black text**.
- **3000 touch:**
  - Tap selects on release.
  - Over 8 px is a drag (40 px per row), and a release while moving gives momentum (≤ 40 rows).
  - A pressed row shows #646464.
  - The selected row shows a **LOAD button** over BPM/KEY. The loaded track's row has none; it shows a green
    triangle with a green title and BPM.
- **Preview:** a finger on a row's mini-wave plays from that point (green line follows the drag; the title is
  bright green #00FF00). Rows already previewed stay dark green #168B16. Audio goes to the DJM-A9 LINK CUE
  (§5.4).
- **Other screens:** SORT / LIST MENU / TAG LIST MENU as 3000 modals; TRACK FILTER (opened by forging stock's
  KEYCMD 13 event); MY TAG page; letter jump (a fast knob turn gives a boxed letter, done as a binary search
  with exact knob deltas); SEARCH results in the 3000 layout.

### 2.3 INFO
- 3000 layout with 164x164 artwork. While a track plays it uses our copies of title and key, because the stock
  INFO page was garbled on the deck.
- **rekordbox 7.2.19 exports:** MAIN leaves the model's title and key slots empty, so the header and KEY fall
  back to the cursor row's title and key seen within 5 s before the load. That was later traced to an old
  PIONEER folder on the stick.

### 2.4 UTILITY
**Six 3000 categories:** DJ SETTING, DISPLAY (LCD), DISPLAY (INDICATOR), PRO DJ LINK, SYSTEM, INFO. Category
tiles, radio-list options, #191919 rows, #254580 focus, and a #007DE1 radio dot.

**RC1 item order (30):**
- DJ SETTING: PLAY MODE, EJECT/LOAD LOCK, QUANTIZE BEAT VALUE, HOT CUE AUTO LOAD, HOT CUE COLOR, AUTO CUE LEVEL,
  **KEY SHIFT**, **KEY SYNC BUTTON**
- DISPLAY (LCD): LANGUAGE, LCD BRIGHTNESS, TOUCH DISPLAY CALIBRATION, SCREEN SAVER, **LIGHT MODE**,
  **BPM DECIMALS**, **WAVEFORM COLOR**, **WAVEFORM CURRENT POSITION**
- DISPLAY (INDICATOR): SLIP FLASHING, ON AIR DISPLAY, JOG BRIGHTNESS, JOG INDICATOR, DISC SLOT ILLUMINATION
- PRO DJ LINK: PLAYER No. (AUTO, 1..6 with player56), LINK STATUS, MIDI CHANNEL, DUPLICATION
- SYSTEM: HISTORY NAME, DIGITAL OUT, AUTO STANDBY
- INFO: **TEST LOG**, VERSION No.

**Removed or hidden** (`patch_main.UT_HIDE`):

| item | why |
|---|---|
| MODS, LINK CUE, WAV 32-BIT | Native and always on for the 3000. They are ON / BOTH at every boot; a `NOMODS` file on the stick is the hidden kill switch. |
| REKORDBOX BUTTON | V4n23: the rekordbox key is stock again; a saved ON is ignored. |
| LINK CUE DIAG | Debug only (`CDJ_UT_DIAG=1` shows it). |

**Where our values are saved.** Spare settings bits (byte 7 bits 4-7, byte 6 bits 0/4) hold our display items.
The HISTORY-name record tail byte holds the rest:

| bit | holds |
|---|---|
| 0-2 | BEAT JUMP |
| 3 | WAVEFORM COLOR high bit |
| 4 | KEY SHIFT |
| 5 | (old REKORDBOX BUTTON) |
| 6 | KEY SYNC BUTTON |
| 7 | "ours" |

That record tail only works with a HISTORY name of 29 bytes or less.

**Saving BLUE wiped every setting (fixed in V3rc2).** Settings byte 6 bit 0 turned out to be stock's "invalid
record" flag, so storing WAVEFORM COLOR = BLUE there wiped all settings. The fix moved it into the HISTORY tail.

A help text under the rows explains KEY SYNC BUTTON (our addition; we have not seen whether the 3000 shows
UTILITY help).

### 2.5 SHORT CUT
- 3000 layout with flat tiles #3C3C3C / #007DE1: WAVEFORM / PHASE / 4 BARS, HOT CUE AUTO LOAD, QUANTIZE,
  WAVEFORM COLOR, POSITION, SCREEN MODE.
- Stock zones 53..69 are moved to the 3000 tiles by the `v2needle` MAIN pokes.

### 2.6 Touch
- **Touch is handled in MAIN**, not the GUI. The panel decoder calibrates the point to 0x0B06C768 {+12 x, +16 y}.
  `touch_event` (0x084ECCF8) uses screen class `*0x0B54336C`, a 70-zone table at 0x081010A0, and the current
  zone `*0x0B56A3B0`.
- Every 3000 tap target is therefore MAIN work. We redirect the two `touch_event` literals to modsmenu
  `v3e_touch` / `vt_zones`, and `v2needle` re-pokes the stock zones:

  | zone(s) | new target |
  |---|---|
  | 0 | strip (79,405,640,75) |
  | 2 | phase meter |
  | 3 / 15 | header tiles |
  | 4, 7..14 | pad row |
  | 30 | TRACK FILTER key grid |
  | 53..69 | SHORT CUT |
  | Link Cue row zones | browse rows |

- Gestures (`vt_drag`) run every panel frame while active. Knob injection (`0x084E1214(n)`) is one detent per
  ~12 panel frames and is done closed-loop.

### 2.7 Day mode and font
- **LIGHT MODE** (OFF / LIGHT / FULL) is the one deliberate non-3000 feature: a light theme. LIGHT draws dark waveforms on a light band
  (the deck's help text); FULL lightens everything.
- **Font:** Cueline Sans (`mods/v2ui/fonts/CuelineSans/`, our own font, SIL OFL 1.1) is the UI font. It is used for
  the v2 glyph sets (trimmed to the glyphs each size draws, `CDJ_V2_FONTTRIM`) and, through `font3000`, as
  the stock GUI's Latin font at 22.5 px; Roboto Condensed fills the glyphs it lacks.

### 2.8 Language trim
- **GUI `lang7`** (since 2.3): EN FR DE IT NL ES PT kept, the 11 other languages dropped; their table entries fall
  back to English. (Up to 2.2: `lang2`, English and Spanish only.)
- **MAIN `lang7`:** the LANGUAGE item has 7 options; other stored values are clamped to English.
- **MAIN `reclaim`:** see §1.2.

---

## 3. Waveform pipeline

### 3.1 Data
- **Detail.**
  - PWV5 colour detail (150 entries/s; u16 with R 15-13, G 12-10, B 9-7, height 6-2) comes as GUI message
    0x37. The blue PWV3 detail is 0x36.
  - The `rgbdetail` poke forces the RGB request first: stock picked it from a byte in the media record, which
    left the band BLUE on decks set to BLUE [deck, V4m3].
  - `three_band` adds PWV7 (3-band detail, .2EX) and PWV6 (3-band overview) fetches into the stock handlers
    and recolours the stock overview for tracks without 3-band data.
- **Overview.** 600 records of 6 B at GUI 0x0E5B748C.
- **Grid.** Message 0x2B. Records are 20 B {bpm×100, beat no., time ms, ...}.
  - MAIN's copy (sender struct 0x09FF8608) is malloc'd and writable.
  - **MAIN never reads it while playing** [emu, watchpoints]: quantize, beat jump and LINK beats come from the
    engine/DSP side. So GRID ADJUST is not just a buffer patch (§11).

### 3.2 The band on the VDC4 hardware layer GR2 (`mods/v2ui/hwband.inc`, V4 "HWBAND")

**Layer setup.**

| item | value |
|---|---|
| GR2 window | x 16..783 (768 px), y 122..305 (184 rows), RGB565 |
| line offset | 3584 B |
| ring | **896 columns** (128 more than the window), every column stored twice (slots s and s+896) |
| ring A | 0x0CB38000-0x0CBD9000 (0xA1000 B, uncached writes) |
| ring B | 0x0CA94000-0x0CB35000 (0xA1000 B, uncached writes) |

- Because the ring is 128 columns longer than the window, the up to 128 columns entering per frame (in either
  direction) always land in slots the panel is not scanning. There is no tearing and no ordering hazard with
  the base write.
- **Baked into the ring per column:** waveform, beat ticks, cue / memory / hot-cue marks (with badge letter),
  loop half-height and wash.
- **On GR3** (the normal frame buffer), the band area x 18..781 is the **chroma-key colour 0x0001** (K1,
  key register 0x00000800). Fixed overlays sit on it: playhead, pads, MASTER PLAYER, beat numbers, loop label,
  ZOOM-GRID. That area is redrawn only when its inputs change. The chroma key is proven on the deck.

**Scrolling: STA_POS is ignored on the real VDC4 [deck].**

- The V4f build used base = ring + 2·slot (8-byte aligned, 4-px steps) plus FLM6.STA_POS for the remainder.
  On the deck it moved in 4-px jumps.
- V4g keeps the base 4-px aligned and moves the GR2 **window left by the remainder** r = 0..3 instead (AB3
  GRC_HS, window x 16-r .. 787-r, 772 px wide). FLM2 and AB3 are committed in the same frame (UPDATE |= 0x11),
  just before the GR3 base write.
- The extra columns only ever land under GR3's opaque black edges (x 0..17 / 782..799).
- Result: 1-px steps, 60 fps on the deck [deck, V4g: F 60, ~2-3 ms GUI draw]. Our emulator (not shared) was
  later changed to reproduce this.

**Rebuilds.** A zoom / look / marks / loop change, or a jump of more than 128 columns, builds the **hidden** ring
on a time budget while the shown ring keeps scrolling (or holds on a jump). The rule: at least 64 columns per
frame; more while the paint is under 10 ms old; finish in-frame when 320 or fewer columns are missing. GR2 then
switches at one vsync.

**On/off.** All register writes happen in `hb_commit()` at the end of the frame. The band is live only on our
player screen, with an analysed track loaded, no pop-up, and not in update mode. Any other frame turns it off
*in the same frame* and uses the software band, held for 1 s so it does not flap. There is also a watchdog
(more than 3 flips without our commit), and GR3's key is re-asserted if stock's VDC Start resets DISP_SEL.

**Sub-pixel phase rings (history).**

| build | change | evidence |
|---|---|---|
| V4s/V4m2 | Rings A and B also serve as phase partners: one holds whole columns, the other is shifted by half a column (`ph_blend`, 174/174 weights). The frame picks the ring matching the position's fraction. | — |
| V4n5 | Zooms 1-2 (shift ≥ 2) used quarter phases (1/4, 3/4; weights {192,128}), against white-peak blinking. | — |
| **V4n24 (RC1)** | **Zooms 1-2 step in whole pixels**, like the CDJ-3000: both rings hold the same unblended columns, so every displayed image is an exact 1-px shift of the previous one. Zooms 3-4 keep whole + half (174/174). A forward-motion guard never steps half a pixel back. | Deck video of V4n23 at zoom 1 showed the frame difference alternating high/low every frame: two blended phases cannot keep a 1-px peak's brightness and move it in equal steps. Fix is [emu]; deck confirmation [open]. |

**Cost** [emu]: band work went from about 376k to about 22k instructions per frame while playing; the whole GUI
frame is -31 %.

### 3.3 Colours (`re/WAVE3000_SPEC.md`)

The values are measured from 3000 frames (emulator PNGs, a reference capture, video), not read from tables. The
waves on the 3000 are drawn by code with literal colours.

| look | detail band | overview (bottom strip) | browse mini-wave |
|---|---|---|---|
| 3BAND | low #0057EA, mid #C06400 inside the low envelope / #FE9B28 beyond it, high #F7EBD5; mirrored; ~64-67 % of the half-height; weights low ×1.2, mid ×0.6, high ×1.2; 1-px edge blend | stacked from the baseline: low #0055E1, mid #FFA600, high #FFFFFF | 3000 stack, bottom-anchored (V4n21) |
| RGB | one hue per column normalised to the strongest channel, shade 1.0 at the axis -> 0.48 at the envelope | outer layer colour ×0.40, inner full colour | inner full + outer ×0.4 |
| BLUE | flat per column, #0050C8 -> #CEE7FF with whiteness, tip ~70 % | vertical gradient #066EBE -> #067CD6 -> #0890F8 | blue ramp, white tip |

- **Played part of the overview.** The 3000 measures ×0.75 for every look. On the NXS2's
  small overview that was barely visible, so **RC1 uses ×0.56** (`ov_played`, V4n24), and the BLUE played ramp
  is a further ×0.75 darker.
- **Detail band:** no played/unplayed split, as on the 3000.
- **3BAND gaps we tuned by eye on the NXS2:** mid ×0.75 and high (h-2)×3. MAIN's high curve is weak and gave a
  constant 2-px cream line.
- **No 3000 capture exists** of the RGB overview/detail or of a moving BLUE detail [open].

---

## 4. MAIN <-> GUI channels

### 4.1 SPI frames (`re/V2_PROTOCOL.md`)

**Transport.** Full-duplex SPI (MAIN MSIOF1 / GUI RSPI1, DMA) exchanging **4 KB frames** continuously.

**Frame and message layout.**

- A batch frame: bytes +0x00..+0x17 are 0; +0x18 holds the message count, repeated 4 times.
- A message: `[seq u8][type u8][len u16 BE]` + payload + 4×0 + 4-byte checksum + `FF FF FF FF`.
- Long payloads continue at byte 0 of the next frame(s).
- Bulk payloads start with a chunk header `[total u16][index u16]` (1-based).

**Main message types.**

| type | content |
|---|---|
| 0x03 | heartbeat (every frame) |
| 0x39 | UI model |
| 0x37 / 0x36 | detail waveform |
| 0x35 / 0x34 | overview |
| 0x2B | grid |
| 0x32 | markers |
| 0x05..0x16 | image slots |

**GUI dispatcher.** It copies each message header to 0x0F682190 ([seq][type][len][last][index]) at 0x0E50112C.
Unknown types are logged and ignored, which is why we could add **0x31**.

**MAIN side.**

- `gui_comm` receives into a **ring of 3 RX slots** 16 KB apart (0xA9072B38 + slot<<14). TX is the 4th slot
  (0xA907EB38). A parsed slot is cleared.
- usblog picks the slot with the right magic and the highest head; reading slot 0 only lost GUI records
  [deck, V4m2].
- The MAIN heartbeat block is 0x0B568C9C (0x1A8 B), filled from a workspace at 0x0B568E6C by the builder
  0x084E2CE6..0x084E3938. The copy sent to the GUI is 508 B.

### 4.2 Heartbeat words we use or publish

Offsets are block offsets: MAIN 0x0B568C9C = GUI 0xFFF88000. Wire offsets are 4 more.

| offset | meaning | source |
|---|---|---|
| +0x14 | our publish word 2 (magic 5). **Page** in bit 28 (written in the odd 64-ms slots). Page 0: SCREEN MODE bits 0-1, master key code bits 8-12, pressed-row bits 13-15 + bit 26, etc. Page 1: KEY SHIFT (bit 0 ON, 1-5 semitones+12, 6 panel, 7 rb mode, 15 valid), TEST LOG mode bits 10-11 (DEV only), bit 14 HOT CUE COLOR OFF, bits 16-18 own player number (1..6), bits 19/20 own SD / USB mounted, bit 21 sixth zoom, **bit 27 KEY FORMAT CLASSIC** | modsmenu (`ks_pub`, `v32_pub`) |
| +0x18 | free in stock (always 0). While SLIP is on: `0x53 ('S') << 24` + the slip position in ms (bits 0-22) = the **slip ghost**. Otherwise the **'K' word** `0x4B << 24`: bit 0 MASTER WAVEFORM on, bit 1 HW BAND LAYER on (kill switches; the GUI keeps the last value while SLIP uses the word), **bit 2 WAVEFORM HALF** (overview + browse rows), bit 3 stock's overview type latched from +0xE8 (written, no longer read since V4n38) | modsmenu `sl_pub` (normal boot only) |
| +0x54 | our publish word 1 (magic 0x4C): LIGHT MODE / BPM DECIMALS / WAVEFORM COLOR / POSITION, phase-meter style, bits 6-23 LINK master slots | modsmenu `mm_copy` |
| +0x58 / +0x5C | player-number confirmed flag / number (0 = blank phase). Mode word *0x0B568C84: 0 steady, 1 blink own, 2 negotiate (cycle 1..4 every 1.5 s) | stock, RE_NEXT_FINDINGS §3 |
| +0x64, +0x70/+0x78 | tempo / position (1/150 s, ms) | stock |
| +0x84 | beat counter (NOT slip) | stock |
| +0xA4 | tempo master player | stock |
| +0xDC | 1 while SLIP is on; +0x88 == +0x84 only while slipping | stock |
| +0xE8 | publish word 3 (magic 7 in bits 29-31; e.g. bit 15 = PLAYER No. offers 1..6) | modsmenu |
| +0x15F / +0x163 / +0x167 | A.HOT CUE state | stock |
| +0x1E0..+0x1EC | V3E_LIST / V3E_ROWS / V3E_PREV / V3E_UI (magics 0xE1..0xE4): list page, rows loaded elsewhere, preview row/column, UTILITY category / PREVIEW mode | modsmenu (free tail) |

**GUI -> MAIN.** We use one word in the GUI TX frame at **+0xFF0**: `"KY"<<16 | valid<<7 | (shift+12)`, the KEY
SYNC target (§9). MAIN caches it every 128 ms (keyshift `ksy_tick`).

### 4.3 Message 0x31 (`mods/w8fetch`: w8send / w8cap MAIN, w8recv GUI)

**Sending.** w8send replaces the MAIN frame packer's last sub-packer call (0x0838EC76..0x0838EC86, normal path
only; the update stream is mode 2 and never gets there).

- It streams through the stock chunk sender 0x083913C2: type 0x31, at most 0x2000 B a frame, and only when
  the frame has room (budget word *0x09A30330 > 0x2030).
- It is charged against the frame budget the same way the stock detail packer charges its own.

**Header and index.** Header `[seq][0x31][len][last][index]`, with **`index = kind << 14 | chunk`** (chunk
1-based, 16-bit field, so kinds 0..3 only).

| kind | payload | GUI SDRAM (w8recv) |
|---|---|---|
| **0** | the tempo master's PWV5 entries | 0x0CA00040 + (chunk-1)·0x2000, chunks 1..0x30 (~21.8 min max) |
| **1** | the master's beat grid: the PQT2 tag from its .EXT, as in the file | 0x0CA80000 + (chunk-1)·0x2000, 1..8 (MAIN clamps at 0x7FFC B) |
| **2** | control record, 32 B: valid, key = master<<24 \| type<<16 \| slot<<8 \| source player, rbid, PWV5 bytes, grid bytes | 0x0CA00000; the receiver writes `'W8M1'` over word 0 and counts +0x3C |
| **3**, chunks 1..2 | cue block of the **loaded** track: `PCO2` header (magic, seq, rbid, length) + raw PCO2 tags; `TITL` record at +0xF80 (magic, rbid, n, ≤ 64 UTF-16BE chars) | 0x0CA90000 |
| **3**, chunks 0x21..0x24 | loaded-track artwork: `PART`, seq, rbid, length 26208, 109×117 RGB565 (stride 112), trailing seq | 0x0CA70000 |

- The artwork rides as kind 3 with chunks starting at 0x21 because kind 4 does not fit in the 16-bit index.
- **Byte order:** the chunk sender for types > 40 and the link hand over 32-bit word values. Byte data
  therefore arrives with each 4 bytes reversed, and w8recv reverses them back. Control words are copied as
  they are.
- **Order** for a new master target: control (valid 0) -> PWV5 -> grid -> control (valid 1). A new target
  abandons the stream in progress. The cue and artwork blocks go out while w8send is idle (ST 0), when
  touch_audio has published a new seq.

---

## 5. Pro DJ Link features

### 5.1 Phase meter WAVEFORM: the master's detail waveform

**Fetch path** (w8send state machine).

1. Each frame, read the target: the master named in heartbeat +0xA4 (another deck than ours), and what it
   plays from MAIN's LINK status table **0x0A371D3C + player·0x124** (+0x28 source player / slot / type, +0x2C
   rbid; rekordbox tracks only).
2. After a debounce, request the stock DB task: mailbox *0x09435CC8, helper 0x084A009A, **code 0x433** (the
   stock CUEWAV requester's PWV5 fetch, handler 0x0828A4F0). Use tid {source player or 0, slot, type, rbid}
   and a reply "mailbox" **0x5738** that no real mailbox uses.
3. `w8cap` replaces 0x0827C2CA..0x0827C2D8 in the DB task's common reply sender 0x0827C2C4. Replies addressed
   to 0x5738 are kept, not mailed.
4. Still in the DB task, the same track's **PQT2** is fetched: open 0x0827A228, tag primitive 0x082545F8 with
   "PQT2"/"EXT", close 0x0827A34E. A PQTZ/.DAT fetch answers empty.
5. `master_mini()` in v2.c draws the master's wave from the buffer, but only when it is valid, the magic
   matches, and the key's player is the current master.

**Status.**

- **[link-emu]** (V4n8): with the 3000 emulator as master, PWV5 (114 KB) and the grid arrived and the master's
  wave was overlaid. PHASE ticks follow the master bar length including pitch (e.g. 1850 ms at +6.3 %).
- **[link-emu + deck], V4n17 [open]:** the 3000 emulator then answered our 0x433 request for its **SD** slot
  with an empty reply (no PWV5; the PWV7 fallback was also empty), so the line is flat.
  - The test image does contain PWV5/7/4/3.
  - Next step: capture what a stock NXS2 that loads the 3000's SD track asks for (dbserver TCP).
- **Interaction:** `three_band`'s `wave3data` is hooked inside the same 0x433 handler, so it also runs for our
  request and swaps its hand-over word 0x081FFFF4. This matters only if a W8 request is handled between the
  deck's own reply and its conversion (noted, never seen).

### 5.2 CDJ-3000 key from its status packet (`ks3k`)

The 3000 status packet (type 0x0a, port 50002) is **1152 B**; the NXS2's is 0x124. We captured it from the
a CDJ-3000 emulator.

| off | field |
|---|---|
| 0x154 | original key {b0 = tonic of the **relative major** 0-11, b1 = mode (0 for all minors seen; 1 major presumed [open]), b2 = spelling −1 flat / 0 / +1 sharp, b3 = valid} |
| 0x158 | MASTER TEMPO flag (byte) |
| 0x15C | sounding key, same form (original + fader semitones; = original with MT on) |
| 0x160 | sounding cents, int32 BE |
| 0x168 | KEY SHIFT in cents, int32 BE (100 / semitone) |

- Camelot number = (b0·7 + 8) mod 12 (0 -> 12). Examples: Ebm = 06 00 ff 01 (2A), F#m = 09 00 01 01,
  Bbm = 01 00 ff 01, Gm = 0a 00 00 01.
- Whether 0x15C includes KEY SHIFT once valid is [open]: +1/+2 moved only 0x168 with MT on.
- **Hook:** status receive at 0x083FE8E8 (call site 0x083FE92A). The stock table stores only 0x124 bytes, so
  the extension is kept separately at **RAMB+0x1E800 + player·8** (`0x4B33` tag + code). A 3000 master's key
  is then published first (`v3e_pub2`).
- **Status:** [link-emu] (V4n12/13, 490 packets, Ebm read correctly). No real CDJ-3000 has been tested.
- **Other routes to the master key:** route A is touch_audio reading export.pdb for the master's rbid; route B
  is the DB client key-id call 0x08253934, used for masters on other media.
- **Known gap:** tracks loaded *from our NXS2's media* show no key on the 3000. The 3000 asks our dbserver for it
  in a way the NXS2 does not answer [open].
- **V4n36a, a 3000 master's KEY SHIFT:** when its 0x16C == 1, ks3k adds round((0x160 + 0x168) / 100) semitones to
  the master key, so KEY SYNC follows a shifted 3000 master [emu, synthetic 3000-format status].

**Our own status packet: the CDJ-3000 key fields (`kx_send`, mods/keyshift, V4n36a).** A CDJ-3000 only accepts a
remote key when the status carries its key block, so the NXS2's status (0x124 B) is sent as **0x180 B** (length
field 0x22 = 0x15C) on a normal boot while LINK KEY STATUS is ON (KSB+100, kill switch). The stock sender's UDP
send (status builder 0x084B8132, send 0x085117CA, once per destination) is wrapped; the descriptor's length is
restored after each send. Stock NXS2s copy only 0x124 bytes (and accept a 3000's 0x480), so nothing changes for
them.

| off | field we send |
|---|---|
| 0x124 | 1 (the 3000 tests it) |
| 0x154 | the loaded track's key {relative-major tonic 0..11, 1 = major / 0 minor, spelling, valid} (default 00 01 64 00) |
| 0x158 | MASTER TEMPO (1 on) |
| 0x15C | sounding key = original + the tempo fader's semitones (MT off: 12·log2 of the pitch); **not** our KEY SHIFT (a 3000 adds 0x164 itself; including it would count it twice) |
| 0x160 | cents, 0 (the engine has none) |
| 0x164 | our KEY SHIFT in cents, int64 BE |
| 0x16C | 1 (without it the 3000 treats the shift ratio as invalid and shows no key) |

Status: [emu] (stock-emulator regression; the 3000-format receive path checked with synthetic packets). A real
CDJ-3000 following our master is [open].

### 5.3 KEY SYNC

Covered in §9.

### 5.4 Link Cue / Touch Preview to the DJM-A9 (`mods/touch_audio`, task `TchAud`)

**Task.** `TchAud` (priority 9, 4 KB stack plus buffers from the firmware's malloc) is created once, from the
DJCONT_PASS hook, on normal boot only.

**What it does.**

- Announces itself as a **device-17 "CDJ-3000"** keepalive to the mixer (unicast, 200 ms). The mixer's address
  is learned from its keepalive on UDP 50000 (`touchaudioip`, hook on the LINK receive path).
- Takes the mixer's **timing packets (type 0x20, 7 ms) on UDP 50004**. Every timing packet is answered with
  one **0x1e audio packet of 336 frames**, 48 kHz s16 stereo, so the mixer's clock paces us. Up to 12 due
  packets go out back to back after a stall.
- The I flag is the engage request and C is a counter. Gain ramps run 0..512 frames (10.7 ms) at start and
  stop. A fading tail follows when the finger lifts.
- **Stop on load:** when own status +0x28 ^ +0x2C changes, the preview stops and stays latched until the
  finger leaves the row.

**Track resolution.**

- rekordbox id -> export.pdb row through an index built a few pages per pass -> file path and ANLZ.
- Works on the deck's own USB/SD or a LINKed player's media (the firmware's NFS mount, drive letters D:..Z:).
- The own export.pdb must never be closed from the task: the DB layer shares it, and closing it hangs loads.

**Formats.**

- WAV 16/24/32 (int / float / extensible).
- MP3 and FLAC through the `tadec` blob (dr_mp3 / dr_flac, public domain / MIT-0) at the layout's tadec
  address.
- AIFF: the V4 notes list it as supported; the older touch_audio README says it was moved into tadec. Please
  check `tadec.c` [open].
- M4A (FAAD2 / ALAC) is opt-in for TEST builds only.

**Status.** The core Link Cue path was deck-proven in earlier milestones [deck]. The V4 refinements (ramps, stop
on load, 3000 row preview) are [emu] / [link-emu]. We could not capture a real 3000's own 50004 stream from the
Mac host; a real DJM-A9 capture is still to do [open].

**Related changes.**

- **wav32** (separate from Link Cue): the play path accepts 32-bit WAV by presenting it as 24-bit PCM and
  packing samples on read. It uses 6 signature sites: fmt, data length, file object, read size ×4/3, pack,
  seek.
- **Scheduling note** (RE_NEXT_FINDINGS §4): the scheduler is strict-priority µITRON. A future decoder FIFO
  task must sit numerically at or above 9 and yield with `dly_tsk`.

### 5.5 Players 5 and 6 (`mods/player56`, cave 0x081C4000)

**Option A** (the NXS2 itself as player 5/6):

- Own number range 1..6 (0x083DFDAC).
- Status builder (0x084B8156).
- Sync-module own-slot switch -> `p56_stubA`.
- UTILITY PLAYER No. list becomes AUTO, 1..6.

**Option B** (peers 5/6):

- Status receive (0x083FE91E) and LNKH slot query (0x083FD212) accept up to 6.
- Media-tracking loops run over 1..6.
- Master detection -> `p56_stubB`.

`gui78` (sources 7/8, for a GUI that knows them) is only in the `all` set.

RC1 builds `--p56=proven` (a1 a2 b1 b2) with a malloc gate on the boot word. Every patch checks the stock bytes
first. The ui3000x rows show "USB LINK5"-style sources.

**Status:** [emu] / [link-emu], plus the V4n13 L1 discovery run. Known limit: a stock NXS2's dbserver refuses
requesters 5/6. That is accepted; the target setup is a DJM-V10 with CDJ-3000s.

---

## 6. Artwork via the MAIN JPU, with a software fallback

- **Stock path** (re/ARTWORK_DECODER.md):
  - `JpegMgrTask` (priority 9) decodes thumbnails on the SH7724 **JPU (0xFE980000)** and **VEU (0xFE920000)**
    via `Jpeg_DecodeThumbs` 0x082C260E.
  - It blocks on an event flag (0x08516784, 500 ms) until the JPU interrupt.
  - Nothing locks the JPU, the VEU or their buffers, so TchAud must not call the decoder directly.
- **Ours (`artj` + touch_audio `ja_req` / `jm_shim`):**
  - We post our own 0x40-byte message to JpegMgrTask's mailbox.
  - The task's free-path literal 0x083D6CF8 now points at `jm_shim`, which runs the stock stage / ParseHdr /
    purge / decode sequence inside JpegMgrTask. The mailbox therefore serialises our decodes with the stock
    ones.
  - The 109×117 RGB565 "big" output is box-averaged to the browse rows' 20×20. For the loaded track it goes
    to the PART block (kind 3, §4.3), from which the GUI scales the header box (35×38) and INFO (164×164).
- **Fallback:** `tadec_jpeg` (stb_image) gives a software 20×20.
  - V4n24: the deck showed **no loaded-track cover**, because the big image came only from the JPU path. When
    the JPU yields no big image but the 20×20 decode worked, that 20×20 is now scaled up and published once
    per track.
  - The JPU path is retried once a second while busy (5 tries). Diagnostic words (AR_STATE, `ldart_diag`) go
    to the V3US log.
- **Emulator:** with a JPU + VEU model added to our emulator (not shared), stock 1.87 artwork decodes
  [emu]. Before that model existed the emulator showed no artwork at all.
- **Status:** the V4n24 fallback on the deck is [open].

---

## 7. Cue colours and comments (PCO2 from the .EXT)

- On every change of the loaded track, touch_audio:
  1. Publishes an **empty** cue block at once, so old cues never outlive a load.
  2. Reads both PCO2 tags (memory/hot cues with their PCP2 entries) from the track's .EXT.
  3. Fills RAMB+0x14000 with header `PCO2` / seq / rbid / length, the raw tags, and the `TITL` record.
- w8send streams the block as kind 3. v2.c parses each new seq once into a small table (24 entries).
- For PCP2 entries of type 1 / 2 (cue / loop) it reads the hot-cue number, time (ms), RGB and comment
  (UTF-16).
- **Drawing:**
  - Hot cues use their **real rekordbox RGB** for badges and band marks.
  - Memory cues use their colour (red by default) for the triangles on the overview and band.
  - The **comment** of the next cue at or after the playhead is shown in the band's top margin, right of the
    cue marker.
- The `TITL` record also gives the header MAIN's export.pdb title for that rbid (V4n24), before the model's.
- **Status:** [emu] with synthetic coloured cues and comments. Hot cues set on the 3000 emulator are part of
  the LINK plan (L5) [open].

---

## 8. Jog

Data path: MAIN builds a 40-B panel tx frame at **0x0AB86780** (builder 0x0844F678, sent about every 9.7 ms
over SCIF2 to the PANL M16C). PANL turns indexes into segment images, so MAIN never sends segments. We never
touch PANL.

### 8.1 Ring LED (`re/JOG_LED_RE.md`)
- **Format.** Only tx byte 2 bits 3:0, as **two 2-bit channels**: A (bits 3:2) and B (bits 1:0).
  - Getters: A 0x084DC640 / B 0x084DC64A, reached through literals 0x0844FA40 / 0x0844FA44.
  - Slots: 0x0B54C09C / 0x0B54C0A0.
- **Stock values.** Stock writes only 0, 1 and 3. JOG BRIGHTNESS maps to level 0/1/3. SLIP flashing toggles
  between the channels.
- **Colour** (blue / red / white) is decided inside PANL and is [open]. **`jogtest`** (TEST) is the probe: from
  20.0 s to ~52.8 s after boot it walks all 16 A/B combinations, 2.048 s each, so the colours can be read on
  the deck. Results are not in the docs yet.

### 8.2 Centre LCD (`re/JOG_CENTER_RE.md`)

Struct **0x0B06C7B4**:

| field | meaning | tx byte |
|---|---|---|
| +0 | red marker 0..85 (inner ring) | 7 |
| +4 | outer pointer 1..135 (one turn = 135 × 1/75 s = 1.8 s) | 9 |
| +8 | slip ghost 0..85 | 10 (slip-on flag in byte 12) |
| +15 | icon bits (VINYL = 0x18) | 8 |

- Positions are in 1/150 s. Stock already shows the slip ghost.
- **`jogcue`** (literal 0x08450414, which is read once inside the tx builder):
  - Stock already puts the **CUE point** on the red marker. In the emulator, the word at 0x09947614 +
    slot·0x88 becomes the cue after CUE.
  - jogcue makes the marker **blink at ~2 Hz** while the playhead (*0x09947478) is 1..300 units (2 s)
    **before** the cue, like the 3000's cue approach.
  - It passes through untouched unless boot == 1, there is no animation state (*0x0B512568 == 0), and byte 9
    holds no canned code.
  - Status: [static/emu]; on the deck [open].

---

## 9. KEY SHIFT front end and KEY SYNC

KEY SHIFT uses our own Key Shift engine (`keyshift`, built from the sources in this package), with the front end
(`mods/keyshift`, modsmenu items, v2ui panel) and KEY SYNC described below.

### 9.2 KEY SYNC (V4n1)

1. The GUI computes the target shift each frame (`ks_publish`). It takes the master key (3000 status §5.2, or
   route A/B) and the own original key. Candidates are M, M+1 and M−1 in Camelot, in the own key's letter;
   the nearest one with |shift| ≤ 2 wins. The result goes into TX +0xFF0 ("KY", valid, shift+12).
2. A tap on the K.SYNC tile calls `ksy_tap`. It applies the shift and turns **MASTER TEMPO on** with a
   synthesized MT press (the MT setter literals point to `mt_set`; level word 0x0B54CB0C).
3. `ksy_tick` (every 128 ms) follows the master.
4. KEY SYNC ends on an own load (MT restored) or KEY SHIFT OFF, and is cancelled by MT off. A manual
   −1/+1/RESET ends it but keeps the shift.
5. A K.SYNC badge (#007DE1) shows in the MT slot. A refusal shows white for 0.6 s.

### 9.3 KEY SYNC BUTTON on pad D/H (V4n24, `re/KEYSYNC_PAD_RE.md`)

- MAIN sees 4 hot-cue buttons with a bank word (A-D / E-H). The 4th button is D/H: panel byte 0x1A bit 0x01.
- The pad lamps are free 24-bit RGB, scaled to 0..40. Pad 3 is tx bytes 34..36.
- **Press:** the decoder literals 0x0844D7AC / 0x0844DEF8 (hot-cue setter 0x084E1974) point to `hc_set`.
  - Index 4/8 calls `ksy_tap` on the press edge and passes level 0 to stock, so D/H never sets, calls or
    deletes a hot cue.
  - All other indexes are stock.
  - Level words: D 0x0B54CBEC, H 0x0B54CBFC.
- **Lamp:** literal 0x0844FF7C (pad-RGB getter 0x084DC684) points to `hc_lamp`, which overrides pad 3 only.

  | lamp state | meaning |
  |---|---|
  | **White** | KEY SYNC on |
  | **Blue** (stock blue 10 64 FF) | key already matches the master: naturally (need 0) or via the current shift |
  | **Blink** | 600-ms refusal |
  | Off | anything else |

- UTILITY **KEY SYNC BUTTON** OFF (default) is exact stock behaviour. It is saved in HISTORY tail bit 6. With
  KEY SHIFT OFF a press is refused (blink); the lamp still shows blue on a natural match.
- There are no tasks, malloc or spawn; every entry tests the boot word.
- **Status:** [static/emu build]. The exact tint on the deck and the bank-1 behaviour are [open].

---

## 11. Known limits and open items

1. **W8 from a CDJ-3000 master is empty.** The 3000 (emulator) answers our 0x433 request for its SD slot without
   PWV5/PWV7. It works with NXS2 masters [link-emu, deck].
2. **The 3000 shows no key for tracks loaded from our NXS2's media** (dbserver request not answered). Our status
   now carries the 3000 key fields (§5.2), checked in the emulators only; a real 3000 is [open].
3. **GRID ADJUST:** MAIN's grid buffer is writable but not read at run time; the row is display-only.
4. **Beat numbers under the band** are compiled out (`V2_BEATNUM`, GUI room in earlier builds).
5. **Link Cue:** in the emulator 4 of 7 cases stop ~7 s late after the finger leaves the row (same on V4n35,
   which passed 110/110 on the real rig): emulator timing, to watch on the deck. A real-mixer capture of a
   3000's 50004 stream is still to do.
6. **KEY SHIFT:** audibility, DSP load and the meaning of DSP state 5 on the deck. Fast double taps on ±1 can be
   swallowed (`VT_GAP` 40 frames). Emulator: "no key -> K.SYNC refused" fails its timing window (since V4n35).
7. **Settings:** SCREEN MODE, TEST LOG and the kill switches are not saved. The HISTORY-tail settings (WAVEFORM in
   byte 30, KEY FORMAT bit 5, KEY SYNC BUTTON bit 6) need a HISTORY name of 29 bytes or less, else defaults.
   Settings byte 6 bit 0 is stock's invalid-record flag, never use it.
8. **The DEV autotest temporary mode** (real inputs only logged) is still in DEV; RELEASE has no autotest.
9. **Players 5/6:** a stock NXS2 server refuses requesters 5/6 (accepted).
10. **Budgets:** MAIN 92.5 % (RELEASE) / 92.6 % (DEV) packed; GUI 2.93 MB under stock.
11. **The emulator does not model:** the panel latch timing, PANL (M16C) LED colours, real DSP timing (Key Shift
    audio), or a real 3000 / DJM-A9 (we use emulator / fake-A9 stand-ins).
12. **Not built in V4:** jogcue (cue-marker blink on the jog centre), jogtest, M4A decoding, players 5/6 on the GUI
    side (`V2_P56`).
13. **Deck coverage:** the real-rig plans passed on V4n35; V4n37 ran on the decks on 2026-11-16 and the V4n38
    change (WAVEFORM now sets overview / browse, detail always FULL) comes from that session. R23U1n / R23U1r have passed the
    emulator gates; their deck runs: see `TESTREPORTS.md`.

---

## 12. Added after RC1 (V4n25 .. V4n38)

### 12.1 Six zooms (V4n32)
Stock's zoom key (heartbeat +0xE0) stays 0..4 (the stock GUI shifts by 4 - key). The CDJ-3000's sixth, most
zoomed-in level (0.5 entries / px) is ours: on the PLAYER screen (UI class 1, not GRID ADJUST, mode 0x0A35F3E0) a
knob move further in at key 4 sets `zm_v` and is swallowed; the first move out clears it (swallowed too); any key
other than 4 clears it. Published in heartbeat +0x14 page 1 bit 21; `v2.c zkey()` maps the six levels onto the HW
band rings (whole-pixel steps at the close zooms, §3.2). Normal boot only (`vt_khook`).

### 12.2 WAVEFORM FULL / HALF (V4n37h, changed in V4n38)
- RE: the stock NXS2 has **no** detail-waveform HALF option; its HALF / FULL is the **overview** type, the rekordbox
  MY SETTINGS "Type of the overview Waveform" (DEVSETTING.DAT payload byte 9: 1 HALF default, 2 FULL), per medium
  in media record +0xA5 (getter 0x08403164); stock MAIN sends it in heartbeat +0xE8 (1 = FULL), which our
  `v3e_pub` owns, so that setting was silently lost in earlier builds.
- UTILITY > DISPLAY (LCD) > **WAVEFORM** FULL | HALF (`wh_v`, default FULL since the HALFBLUE change; HALF before), saved in the HISTORY-name
  record byte 30 (`0x80 | bits`; needs a HISTORY name <= 29 bytes; an older record reads as HALF), published in
  the 'K' word bit 2 (+0x18, §4.2).
- V4n38 (deck feedback): the **detail band is always the mirrored (FULL) 3000 waveform**; WAVEFORM drives the
  **overview strip** (`ov_build` mirrors each column around the centre when FULL) and the **browse rows' mini
  waveforms** (`cell_img`: MAIN's bottom-anchored 86-column wave mirrored around the row centre when FULL). The
  browse row hash includes the setting, so rows redraw on a change.

### 12.3 KEY FORMAT (V4n36)
UTILITY > DISPLAY (LCD) > KEY FORMAT: ALPHANUMERIC (default, Camelot `11A`) | CLASSIC (`F#m`, the 3000's spelling:
Abm Ebm Dbm F# Db Ab Bbm). `kf_v`, saved in HISTORY tail bit 5 (the former REKORDBOX BUTTON bit), published in
+0x14 page 1 bit 27. `v2.c key_name()/key_txt()/kf_key()/kf_list()` convert every key we draw: player KEY box,
header sub-line, deck strip, browse KEY column, KEY list rows, INFO page and pane, KEY SHIFT -1/+1 and the shifted
key, MT-off sounding key, FILTER key grid. The region hashes include the format.

### 12.4 Tempo takeover (V4n34)
After SYNC off the deck keeps the playing tempo (stock behaviour); like stock we show the fader's own position as a
grey BPM where the % was, and while the takeover is pending (fader and playing tempo differ) an arrow next to it
points the way the TEMPO slider has to move (faster = toward the DJ = down) to pick the tempo up.

### 12.5 SOURCE list (V4n31a / V4n32)
Stock's LINK list is model screen 0x00 with slot 0 "LINK" (icon 0x63) and one plain row per linked medium. It is
drawn as the 3000's SOURCE list: player-number box + LINK tag + medium pictogram, "USB LINK2"-style rows, the
cursor medium's info (songs, playlists, date, used / free) on the right; the deck's own SD / USB rows come first
when mounted (+0x14 page 1 bits 19/20). Touch rows are mapped in `touch_map.py` (pitch 64 from y 66 for <= 5 rows).

### 12.6 MENU / SHORTCUT / INFO at 60 fps (D1, V4n36d)
Emulator (guest-time icount) before -> after: MENU 30 -> 60 fps, SHORTCUT 30 -> 60, INFO 4 -> 60 (deck before: 37 /
25 / 41).
- MENU: stock re-composes its menu window (z128) into the GR3 buffer every frame, which made every region "late"
  and repainted the whole frame. In SMOOTH mode the canvas is intact, so only the late windows' rectangle is
  re-sent from the canvas.
- SHORTCUT and INFO: their stock windows (z128-134 / 136-137 / 64-79) are now ours (O_OWN); the page goes through
  the canvas keyed by its inputs (region 11) and is redrawn only on change; no per-frame latch wait.
- The loaded-track artwork scaler lost 4 divisions per pixel (column table + exact reciprocal).
- Close path: the browse hold after leaving one of our screens is timed (4 s, 15 s while MAIN is busy) instead of
  120 painted frames, and the latch wait on entering / leaving SHORTCUT and INFO is back, so the stock empty frame
  is never shown (stress: 0 bad frames in 2 x 50 + 80 cycles, both display models).

### 12.7 Slip ghost, HOT CUE COLOR, help texts, Players 5/6 (V4n32)
- **Slip ghost:** while SLIP is on (+0xDC = 1), the engine pair 0x0994754C {pos150, pos150, ms, ms} keeps running as
  the background position while +0x70 / +0x78 follow the real (looping / scratched) playhead; `sl_pub` publishes
  `0x53 << 24 | ms` in +0x18 and the GUI draws a slip-blue (#28A0FF) marker in the detail band and overview.
- **HOT CUE COLOR:** the stock UTILITY item (word 0x0A35F704) is honoured: published as +0x14 page 1 bit 14 (set =
  OFF), the GUI then draws hot cues in stock colours instead of the rekordbox RGB.
- **UTILITY help texts:** every item the mods add or newly honour has a label + up to 3 lines (`UT_HELP`), shown
  under the rows when selected; the kill rows too.
- **Players 5/6:** MAIN option A/B as in §5.5; +0x14 page 1 bits 16-18 carry the own number (1..6).

### 12.8 Build ID (V4n36 trace)
- `build.sh` sets `CDJ_BUILD_ID = "TAG YYYYMMDD-HHMM HASH8"` (HASH8 = `patch_main.source_hash()`, a sha256 over every
  `mods/` source, path + content); unchanged package sources give the reference IDs above.
- `patch_main.fill_build_record` writes modsmenu's `bld_rec` at the fixed **BLDID = 0x08014180** (menu + 0x180):
  `"BLD1"` + the ASCII ID (48 B), then `bld_u16` = UTF-16 "TAG HASH8" (48 B), the value of UTILITY > **BUILD**
  (INFO, read-only, before VERSION No.).
- DEV: `cmd.py ver` reads it over the network; the RED / USB `V3HB` boot record carries it (format 2, w8..w19).
- The BLACK BOX dump header copies it, so every dump names its build.

### 12.9 Kill switches (V4n36 trace, V4n37r)
Eight UTILITY rows at the end of INFO (after BUILD / VERSION No.). 1 = ON = the feature, 0 = the stock path at its
entry; live, not saved (ON at every boot). The image's item count hides them; `kl_reveal` raises the live count
byte (0x10DE1B98) after a normal boot (RELEASE: always; DEV: while TEST LOG != OFF), so update mode never shows them.

| row | word | effect when OFF |
|---|---|---|
| LINK KEY STATUS | KSB+100 (0x08123064) | our status goes out as stock 0x124 B (no 3000 key fields, §5.2) |
| KEY SYNC | KILLB+0 | `ksy_tap` refuses new KEY SYNC, pad D/H back to stock; switching OFF ends a running one |
| LINK CUE | the existing LINK CUE word (0x080140F4) | no Link Cue / Touch Preview |
| MASTER WAVE NFS | KILLB+4 | w8send does not try the NFS route for the master's waveform |
| MASTER WAVEFORM | KILLB+8 | GUI: phase meter WAVEFORM view shows the grid only ('K' word bit 0) |
| HW BAND LAYER | KILLB+12 | GUI: the detail band in software instead of the GR2 layer ('K' word bit 1) |
| LINK ROW PREVIEW | KILLB+16 | no row touch-preview on a LINKed medium's list |
| BLACK BOX | KILLB+20 | the recorder stops sampling and dumping |

KILLB = **0x080141E0** (modsmenu `kill_v`, menu + 0x1E0). `kl_commit` applies a change at once.

### 12.10 BLACK BOX (V4n37b, `mods/bbox`)
- MAIN only, 1,736 B (RELEASE) / 2,000 B (DEV, with the network stream) placed in the `ks` code range. No hook, no
  task, no spawn: the TchAud loop calls its entry (`t_bbx` word, 0 = not built) once per pass; every call checks
  `*0x0A35DF3C == 1`; one malloc (8,832 B) inside that gate. Off: KILLB+20, blob +4 poke, or touch_audio's NOMODS.
- Sampling: every 20 ms the fast watch entries and the dump keys, every 250 ms stick / play / network / dump,
  every 1 s the counters and the LINK member mask. A watched value that changes is an **event** of 16 B:
  `{u32 tick ms, u32 type | entry << 8 | b << 16, u32 old, u32 new}` in a RAM ring of **512**.
- Entries: play mode; own track (source, slot, type, rbid) and load end (ms, length, result); SYNC / MASTER /
  on-air flags; tempo master; KEY SYNC on and refusal (reason: KEY SHIFT off / no GUI key word / keys unknown or no
  other master / other); KEY SHIFT on + semitones; Link Cue preview, mixer E, election T and counters (underrun,
  resync, send fail, election timeout, open fail, kill edges); NFS W8N tries; cue/tag lookups; LINK join / leave
  mask (P1-6, rekordbox, mixer); dump request + result.
- **Dump** `C:/BLACKBOX.BIN`, opened for append, one self-contained dump per write: a **256-B header** of 64
  little-endian u32 (`'BBX1'`, w2 tick, w3 events written, w4 events in this dump, w5 reason | trigger << 8 | seq
  << 16, w6 request tick, w8-w9 MAIN version, w10 LINK mask, w11 play mode, bytes 48..95 the build record, w24..
  the state snapshot of every watched entry), then the ring's events oldest first.
- Manual: **MENU + BACK held 3 s** (level words; TIME MODE was avoided because its hold toggles AUTO CUE). Auto: an
  error-class event (Link Cue send / open failures, a load that ends with nothing loaded or takes >= 20 s): at
  most 1 per 5 min, 8 per boot, 32 dumps per boot in all. Written only when safe: stick mounted >= 4 s, not
  playing / loading (+3 s), no Link Cue or row preview; a request waits until then.
- DEV: `'V3BB'` 128-B records (w1 tick, w2 first event's seq, w3 count, up to 7 events) on the RED log.
- Decoder: `tools/bbox/decode_bbox.py`. Emu: 30-min soak ~400 events, 0 lost, 0 asserts.

---

## Appendix A: Key addresses (MAIN 1.87 unless marked GUI)

| address | what |
|---|---|
| 0x0A35DF3C | boot state word: **1 = normal boot** (gate for every mod); 2 = update |
| 0x0B56A3E0 | updater state |
| 0x084F30B8 | updater "write this section?" version check |
| 0x0B568C9C | heartbeat block (0x1A8 B); workspace 0x0B568E6C; GUI copy 0xFFF88000 |
| 0x0A371D3C + p·0x124 | LINK status table (+0x28 source, +0x2C rbid) |
| 0x0A35F80C + p·0x414 + slot·0xA8 | media records (+4 drive letter, +8 state, +0xA6 stored WAVEFORM COLOR) |
| 0x0B53D828 | own status packet copy (+0x2A track type, +0x2C rbid BE) |
| 0x0A35F7A0 | play mode (3 playing, 4 looping, 5 paused) |
| 0x09437CD0 | DB context pointer; 0x09435CC8 DB task mailbox |
| 0x083913C2 | stock chunk sender (types > 40) |
| 0x084ECCF8 / 0x081010A0 / 0x0B54336C | touch_event / zone table / screen class |
| 0x0B06C768 | calibrated touch {+12 x, +16 y} |
| 0x0AB86780 | panel tx frame (40 B) |
| 0x0B06C7B4 | jog display struct |
| 0x09947478 / 0x09947614 + slot·0x88 | jog position / cue word (1/150 s) |
| 0x0B0C5258 | ms tick |
| 0x08123000 | KSB, our Key Shift front end (+48 KEY SYNC on, +64 refusal tick, +100 LINK KEY STATUS) |
| 0x08014000 | modsmenu block (`ks` layout): +0x180 **BLDID 0x08014180** build record, +0x1E0 **KILLB 0x080141E0** kill words, then the UTILITY table |
| 0x080140F0 | MODS / LINK CUE (0x080140F4) / WAV 32-BIT words |
| 0x08017C00 | lang2 block (V4n37h; was 0x08017000) |
| 0x08018000 | tadec decoder blob (256 KB arena) |
| 0x081C4000 | players 5/6 cave (p56.bin; announce stub 0x081C7F00) |
| 0x10DE1B98 | UTILITY item count byte (raised by `kl_reveal`) |
| 0x0838EAEC | gui_comm RX-slot memset literal (DEV `hg_hook`) |
| 0x084B8132 / 0x085117CA | status builder / its UDP send (`kx_send`) |
| 0x081E0000 | RAMB |
| 0xA9072B38 + slot<<14 | MAIN gui_comm RX ring (3 slots); TX 0xA907EB38 |
| GUI 0x0E50112C | message dispatcher (0x31 hook); header copy 0x0F682190 |
| GUI 0x0E526626 | stock VDC base write (our paint runs just before) |
| GUI 0xFFFF7700 / 0xFFFF7780 | VDC4 GR2 / GR3 register blocks |
| GUI 0x0CA00000-0x0CA90000(+) | W8 / grid / artwork / cue buffers (§4.3) |
| GUI 0x0CA94000 / 0x0CB38000 | HW-band rings B / A |
| GUI 0x0CC00000 | SMOOTH off-screen canvas (768,000 B) |
| GUI 0x0C700000 | v2ui read-only data copy |

---

## Appendix B: How we share

Only our own work goes in the package; the firmware is always the builder's own copy.

- **Package:** our sources (`mods/**` .s/.c/.py/.inc, build scripts; Apache-2.0, upstream files GPL-2.0-or-later, see `NOTICE` / `THIRD_PARTY.md`), the patcher
  and verifier tools, `build.sh`, the dev tools (`tools/`), these docs, the open fonts with their licences, and
  `MANIFEST.txt` (sha256 of every file; `build.sh` uses it to know the sources are unchanged).
- **Never shipped:** `.UPD` files, decoded images, flash dumps, disassembly, firmware string tables, extracted
  fonts or artwork, keys; anything generated from the stock firmware (the players 5/6 call-site tables and their
  sites JSON, the font tables, the tadec / v2ui blobs) -- `build.sh` regenerates them from **your** `.UPD`; the
  generated icon atlas; third-party firmware content of any kind.
- **Reproducibility:** with the reference toolchain, `PROFILE=release` and `PROFILE=dev` reproduce the reference
  builds named in `build.sh` byte for byte (checked from the exported package in a clean directory).
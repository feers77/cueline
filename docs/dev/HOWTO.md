# How to

Recipes for common changes, the coding rules in one place, and the release process. Read
`docs/dev/ARCHITECTURE.md` first.

## 1. Add a UTILITY item (`mods/modsmenu`)

The stock UTILITY engine walks a table of 60-byte item records. `patch_main.place_modsmenu()` builds our own table:
the stock items, plus the records from `mods/modsmenu/modsmenu.s`, sorted by `UT_ORDER`.

1. **The record.** In `mods/modsmenu/modsmenu.s`, add a record to the matching block (`entries2` for display items,
   `entries3` for DJ-setting items). Copy an existing ON / OFF record:
   ```
   .long  L_MYITEM, OPTS, 2, -1, -1, 1
   .long  0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
   .long  it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
   ```
   Fields: label (UTF-16), options list, option count, two fields left at -1, editable flag (0 = read-only), then the
   stock handlers with our
   `it_fmt` / `it_commit`. Add the label (`.short 'M','Y',...,0`) and, for more than ON / OFF, an options list.
2. **The value word.** Add a `.long` for the option index and map the label to it (see `wordof` and `kl_map`). The
   handlers find an item's word through its label pointer, because the records are copied into another table.
3. **The record count.** `place_modsmenu()` copies a fixed number of records per block (`MM_ITEMS2`, or the count
   expression for `entries3` that tests which labels exist). Update it, or your record is cut off.
4. **Order and category.** Add the label to `UT_ORDER` and to the right group of `UT_CATS` in `mods/patch_main.py`
   (DJ SETTING, DISPLAY (LCD), DISPLAY (INDICATOR), PRO DJ LINK, SYSTEM, INFO).
5. **Saving** (optional). Free storage is scarce:
   - spare settings bits used so far: byte 7 bits 4-7, byte 6 bit 4 (see `mods_load` / `mods_save`);
   - the HISTORY-name record tail (`hist_save`; only with a HISTORY name of 29 bytes or less);
   - **never** settings byte 6 bit 0 (stock's invalid-record flag).
   Unsaved items reset at every boot; say so in the help text.
6. **Publishing to the GUI** (if the renderer needs it). Put the value into a free bit of a publish word in `mm_copy`
   (heartbeat +0x14 page 0 / 1, +0x18, +0x54, +0xE8; see ARCHITECTURE §2.1) and read it in `v2.c` from `DECK`.
   Document the bit in `docs/dev/ARCHITECTURE.md`.
7. **Help text.** Add an entry to `UT_HELP` in `mods/v2ui/v2.c` (label, then up to 3 lines).
8. **Gate.** Any code your item triggers at run time checks `*0x0A35DF3C == 1`.
9. **Build and check** `build.log`: `place_modsmenu` prints the final item list. The modsmenu block and table must stay
   below the lang2 block (0x08017C00 in the `ks` layout); the patcher fails with "is not free" otherwise.

A kill switch is the same idea with a word in `kill_v` (block + 0x1E0), a record in `entries5`, and a label in
`UT_KILL`. Its feature tests the word at its entry and takes the stock path when it is 0.

## 2. Add or change a screen (`mods/v2ui/v2.c`)

1. **Find the screen.** The UI model's screen id is `MODEL[7]` (UI model 0x39). `screen_mode()` maps ids to our
   modes (`M_PLAYER`, `M_BROWSE`, `M_SHORTCUT`, `M_PINFO`). Add a case, or a new mode, only for ids you fully draw.
2. **Draw by regions.** Use `need(region, key)`: hash every input the region shows into `key`; the region redraws only
   when the key changes. Never redraw per frame "just in case": it costs GUI CPU and fps.
3. **Hide or keep stock windows.** `oclass()` sorts stock windows into overlay (re-blit), own (hidden, we draw), hide,
   keep. Inventory **every** stock window and banner that can appear on that screen (pop-ups, "loading", warnings) and
   decide for each. A stock banner left on top of our screen blinks.
4. **Touch.** Touch is handled in MAIN. Add the targets to `mods/v2ui/touch_map.py` (the single table of drawn
   rectangles and their actions), then to modsmenu's `vt_zones` (`touch_vt_zones.inc`) or the stock zone pokes in
   `v2ui.py`. `python3 mods/v2ui/touch_map.py --audit` lists dead or misrouted targets.
5. **Data from MAIN.** Use existing models first. New data needs a publish bit (small values) or message 0x31 (bulk,
   `mods/w8fetch`; the 16-bit chunk index allows kinds 0..3 only).
6. **Build flags.** Gate optional code with a `-DV2_...` flag and add it to `V2_FEAT` in `build.sh` only when it is
   ready.
7. **GUI room.** Check the GUI section size in `build.log` after every change; it must stay at or below stock.
8. **Update screen.** Your mode must return `M_NONE` while `UPD_STATE` is set (`screen_mode()` already does).
9. **Test on a deck** in both LIGHT MODE settings, with stock pop-ups triggered (eject, LINK errors, track loading).

## 3. Add a DSP feature (`mods/ownks`)

The only DSP code we own is the Key Shift stage. A new DSP feature follows the same pattern:

1. **Code** in C under `mods/ownks/dsp/`, built with the tic6x toolchain (`dsp/build_toolchain.sh`, then
   `dsp/build.sh`; the tools are found through `CDJ_TIC6X`). Keep it freestanding: no libc, no heap.
2. **Placement:** our section sits at DSP 0x805C0000, in DDR the stock program never touches
   (0x80570000-0x80600000). Large state goes into a NOLOAD section initialised on the first call, so the boot table
   stays small.
3. **Hook:** the audio pipeline's L2 trampoline (0x0080DD50) already calls `ks_fill`, which runs the stock pipeline
   first. Add your processing there, after the stock call, on the finished block (16 frames, planar, 24-bit
   left-justified in 32-bit words). Keep an exact bypass when your feature is off.
4. **Control:** extend `struct ks_ctl` (`ownks.c`). MAIN writes fields with the stock "write words" request (type 10,
   id = DSP address - 0x008C8800), as `oks_dj` does in `mods/ownks/main_ownks.s`. Resend periodically: the DSP keeps
   the last value but may restart.
5. **Boot table:** `mods/ownks/ownks.py` checks the 16 stock sections by sha256, appends ours, and rewrites the loader
   constants. If your section grows, check the table still ends below 0x081C22C8.
6. **Checks:** add your invariants to `ownks.check()` (run by `verify_update`).
7. **Measure:** cycles per block (the current stage costs about 2,300 cycles per 16-frame block while shifting). The
   real DSP clock is not known to us; keep the added load small.
8. **Commit the rebuilt DSP image** together with its sources only if you changed the DSP code, and say which
   toolchain built it.

No runtime code writes to the DSP: code is loaded by the stock boot path only.

## 4. Add a MAIN hook

1. Find the call site in the NXS2 1.87 MAIN image. Prefer a **literal redirect**: a `mov.l @(disp,pc),rN; jsr @rN`
   whose literal only that site reads (`sigpatch.literal_pool_reads()` tells you).
2. Write `mods/<mod>/main_<name>.s`. First instruction block: load `*0x0A35DF3C`, compare with 1, and jump to the stock
   target when it is not 1. Tail-call the stock target at the end.
3. Add the `Mod(...)` record to `MODS` in `mods/patch_main.py` (signature or literal + expected stock value,
   `fw_versions=('1.87',)`).
4. No `.long own_label` (the code is not linked); use `mova` or PC-relative loads. Clobber only what the site allows
   (r0-r7 for trampoline hooks).
5. Run-time data goes into RAMB at a documented free offset (`mods/layout.inc`), zeroed on first use.
6. Never `malloc`, spawn or count before the boot gate. Never close the deck's own `export.pdb`.

## 5. Coding rules (summary)

1. Boot gate: nothing of ours counts, allocates, spawns or hooks unless `*0x0A35DF3C == 1`.
2. GUI section at or below the stock size.
3. Never change what draws the update screen; no GUI timing pokes.
4. Labels: every build raises both labels; rollback needs UTILITY > DUPLICATION > DEFAULT, then the official 1.87.
5. No Pioneer bytes in the repository; everything stock-derived is generated from the user's `.UPD` at build time.
6. No CDJ-3000 firmware content (code, data, names, addresses).
7. Check every patched stock value before writing it; fail the build when it differs.
8. Physical checks (stick, cables, power, export) before blaming the firmware.
9. A deck test before anything is called done.

## 6. Release process

Maintainers only. A release has one RELEASE and one DEV reference build from the same sources.

1. **Freeze and tag.** All changes merged; update `CHANGELOG.md` and the release notes; choose the tag
   (`R22R2r` / `R22R2n` style) and the bump (above every previous release).
2. **Rebuild from a clean clone**, both profiles, with the reference toolchain (`REF_TOOLS` in `build.sh`):
   ```
   git clone <repository> cueline && cd cueline
   ./build.sh /path/to/C2KNXS2.UPD
   PROFILE=dev ./build.sh /path/to/C2KNXS2.UPD
   ```
   Build twice; the two outputs must be byte-identical (reproducibility).
3. **Gates:** verify and bootcheck PASS for both; the racegate PASS for both (maintainers' emulator); GUI section under
   stock; packed MAIN fits.
4. **Deck test:** install the RELEASE build from stock with a small stick; smoke test and the rig plans
   (`docs/dev/TESTING.md`); an update from the build back to stock (DEFAULT, then the official 1.87); then the DEV
   build for the rig plans that need it. Record the results.
5. **Publish the references:** the sha256, build ID and labels of both builds go into `build.sh` (`REL_SHA`, `REL_ID`,
   `DEV_SHA`, `DEV_ID`, bumps), `README.md` and the release notes. Regenerate `MANIFEST.txt`.
6. **Cueline Builder delta** (for users without a compiler):
   ```
   python3 builder/mkdelta.py C2KNXS2.UPD out-release/C2KNXS2.UPD builder/cueline.delta \
           --release <TAG> --build-id "<build ID>" --report delta_report.txt
   python3 builder/cueline_patch.py C2KNXS2.UPD          # must reproduce the published RELEASE sha256
   ```
   `mkdelta.py` stores only our bytes: it copies runs of stock bytes by offset from the user's own images and fails
   if a literal run of 24 bytes or more also occurs in the stock images. It also checks the round trip. The Windows
   exe is built with `builder/build_exe.bat` (pinned Python and PyInstaller); publish its sha256 too.
7. **Publish:** the tag, the source archive, `cueline.delta`, the Builder and every sha256. Never attach a `.UPD`.

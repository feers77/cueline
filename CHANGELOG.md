# CHANGELOG

## 2.1.1 -- 2026-11-20: RELEASE `V4r211e` / DEV `V4n211e` (labels MAIN 2.11 / GUI 2.05, source hash `1c1a45f3`)
Link Cue fix release: 2.1 plus the changes below, nothing else. Changes since 2.1:
- **Link Cue with two Cueline decks (bug fix):** the mixer keeps a *single* Link Monitor slot and plays one source
  at a time. Until now every Cueline deck claimed that slot permanently, so two linked Cueline decks fought over
  it: the preview stuttered and you could hear the other deck. Now a deck claims the slot only while you are
  actually using Link Cue on it (a preview touch or Touch Cue) plus a few seconds, and an idle deck announces
  nothing at all -- so there is no collision, the deck you touch last takes the monitor, and it all happens by
  itself with no menu action.
  This is **not new in 2.1**: the same code is in 1.92 and earlier. It only ever showed when two decks ran Cueline
  with Link Cue at the same time, which is why a single Cueline deck was never affected.
- **UTILITY > PRO DJ LINK > LINK CUE (OFF / PREVIEW / CUE / BOTH) is visible in the release build** -- it used to
  appear only in developer builds -- and it is now saved across a power cycle (default BOTH). Handy as a manual
  override: set one deck to OFF and only the other one ever feeds the mixer. It is saved only when the deck's
  HISTORY name is 23 characters or shorter; with a longer name it comes back as BOTH.
- **Still being improved:** the hand-over from one deck to the other takes a moment, so the monitor starts with a
  short delay; and if you hold a preview on both decks at the same time the audio can still interleave for a few
  seconds. Both are on the list for a later release.
- **Nothing else changed:** same features, same screens and the same source as 2.1 otherwise.
- **Versioning:** MAIN 2.11 / GUI 2.05 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows
  `Cueline-2.1.1 <hash>`. 2.1.1 installs over 2.1 without a factory reset.

Known issues: the WAVEFORM meter may sit 1 pixel row off vertically; PHASE and 4 BARS views unchanged (CPU).

## 2.1 -- 2026-11-20: RELEASE `V4r21` / DEV `V4n21` (labels MAIN 2.10 / GUI 2.04, source hash `e2a70b09`)
Stable: tested in our emulator and confirmed on real decks. Changes since 1.92 beta:
- **Settings survive power-off again (bug fix):** on 1.92, KEY SHIFT, KEY SYNC, CLASSIC key format and the BEAT
  JUMP value could come back changed (forced ON / CLASSIC) after switching the deck off and on. Fixed, confirmed on
  real decks with a 2.1 development build. Cueline's settings are now stored in a **versioned, checksummed** record:
  a damaged or unknown record falls back to the defaults instead of odd values, and settings saved by 1.92 are
  carried over.
- **Stock pop-ups drawn correctly:** the deck's own dialogs (MY SETTINGS, REMOVE ALL TRACKS and the other stock
  pop-ups that Cueline does not redraw) are drawn by the deck itself in their normal place, with the selected option
  readable (dark text on the white cursor bar). Editing a value in UTILITY no longer leaves a blank box over the
  value list.
- **Green KEY on the selected row:** the harmonic-match green KEY cell now also shows on the cursor row in BROWSE,
  as on the CDJ-3000.
- **Hot-cue badges on the browse strip:** the mini overview at the top of BROWSE shows the loaded track's hot cues,
  memory cues and cue mark (CDJ-3000 style).
- **Preview gesture (CDJ-3000 style):** the row you press is the one that is previewed for the whole gesture;
  sliding up or down while previewing no longer switches tracks (left / right still seeks), and the previewed row
  ends selected with LOAD. A press on the preview column never scrolls the list.
- **Update safety:** the 3BAND waveform code now also stays inactive in update mode, like the rest of Cueline.
- **Master waveform over LINK, diagnostics:** more robust reading of the master's waveform data block and a
  diagnostic for the CDJ-3000 "error" reply we have seen, to track down an empty WAVEFORM meter with some 3000 setups.
- **Cueline Web Builder:** build Cueline in your browser, nothing to install; your file never leaves your computer.
- **macOS app:** `CuelineBuilder-macOS.zip` (Intel and Apple Silicon), drag and drop like the Windows builder.
- **Versioning:** MAIN 2.10 / GUI 2.04 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-2.1 <hash>`.

Known issues: the WAVEFORM meter may sit 1 pixel row off vertically; PHASE and 4 BARS views unchanged (CPU).

## 1.92 beta (release candidate of 2.0) -- 2026-11-19: RELEASE `V4r60j192` / DEV `V4n60j192` (labels MAIN 1.92 / GUI 1.86, source hash `c5e8e0f3`)
Pre-release: may contain bugs. Changes since 1.91 beta:
- **MY SETTINGS now loads from USB again (bug fix):** inserting a USB stick that holds your rekordbox MY SETTINGS
  makes the deck offer its own "MY SETTINGS" LOAD dialog. On 1.89–1.91 that stock dialog was hidden behind the
  Cueline screen as a black box, so its LOAD button could not be pressed and the settings never loaded. The dialog
  is now shown by the deck in its normal place with its button working. Your deck's own menus — TAG LIST, SORT,
  LIST MENU, LOAD PREVIOUS TRACK — are drawn exactly as before.
- **Versioning:** MAIN 1.92 / GUI 1.86 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-1.92 <hash>`.

Known issues: the WAVEFORM meter may sit 1 pixel row off vertically; PHASE and 4 BARS views unchanged (CPU).

## 1.91 beta (release candidate of 2.0) -- 2026-11-18: RELEASE `V4r59j191` / DEV `V4n59j191` (labels MAIN 1.91 / GUI 1.85, source hash `fe67930a`)
Pre-release. Changes since 1.90 beta:
- **LINK WAVEFORM meter on its own hardware layer (GR1)** (`-DV2_GR1METER -DV2_SC0BYP`, `mods/v2ui/gr1meter_*.inc`):
  the master's waveform scrolls on the display's GR1 layer at full width and full resolution, smooth in every
  state (playing, paused, unsynced, as master). The same layer is used in all of them, so there is no switching
  between hardware and CPU drawing; the CPU strip only fills in for a few frames while the layer is rebuilt after a
  zoom change, a jump or a new master waveform.
- **The main waveform band is drawn alone on its own layer again** (GR2): the 1.89/1.90 shared-layer meter is gone,
  and so is its flicker.
- **WAVEFORM meter colours:** the GR1 colour matrix now uses the documented pass-through (unity gain 0x100,
  DC offset 0x80, as Renesas' VDC5 driver), so mid and dark colours are no longer crushed (before: violet-blue look).
- **WAVEFORM meter 1-pixel horizontal alignment fix** (scaler 0 horizontal start in the SC0BYP setup).
- **Far-zoom flicker fixed** (the slight white flicker of thin peaks at the farthest zoom levels in 1.90).
- **Versioning:** MAIN 1.91 / GUI 1.85 (DEV and RELEASE alike); UTILITY > BUILD shows `Cueline-1.91 <hash>`.

Known issues: the WAVEFORM meter may sit 1 pixel row off vertically; PHASE and 4 BARS views unchanged (CPU).

## 1.90 beta (release candidate of 2.0) -- 2026-11-18: RELEASE `V4r58j190` / DEV `V4n58j190` (labels MAIN 1.90 / GUI 1.84, source hash `5f21f1ac`)
Pre-release. Changes since 1.89 beta:
- **LINK strip no longer jumps when your deck is the master:** with no remote master, the PHASE ticks are placed
  on the main band's own columns (the band's grid), so they stay locked to the band.
- **Smooth strip while your deck is paused or cued:** the GR2 hardware meter is used only while your deck plays
  forward; paused / cued, the CPU strip with half-column steps takes over (no small jumps while the master plays).
- **Cueline Builder:** its final message now lists the install steps, including unplugging the Pro DJ Link (LAN)
  cable and UTILITY > DUPLICATION > DEFAULT before installing (and for going back to stock).
- **Versioning:** MAIN 1.90 / GUI 1.84 (DEV and RELEASE alike); UTILITY > BUILD shows `Cueline-1.90 <hash>`.

Known issue: a slight white flicker at the farthest zoom levels (1-pixel steps of thin peaks at slow scroll
speeds); to be addressed for 2.0.

## 1.89 beta (release candidate of 2.0) -- 2026-11-18: RELEASE `V4r58h189` / DEV `V4n58h189` (labels MAIN 1.89 / GUI 1.83, source hash `b5b0238d`)
Pre-release. Changes since v4.0.0:
- **LINK phase meter on the GR2 hardware layer** (`-DV2_GR2METER`, `mods/v2ui/gr2meter.inc`): the WAVEFORM view
  is drawn by the display's GR2 layer once the master has been steady for 500 ms (CPU strip otherwise, same look);
  even 1-pixel scrolling with half-column steps (`-DV2_MSUB`), no blinking grid ticks; its beat spacing matches
  the main band at every zoom. The PHASE view follows the band's zoom scale (before: a fixed 100 px/s) and the
  own-deck line uses the band's smoothed position (CDJ-3000 style).
- **LINK OFFSET** (UTILITY > PRO DJ LINK, both profiles): OFF | -10 ... +55 ms, moves the meter's master line
  earlier; default OFF (= like the CDJ-3000), not saved.
- **Master waveform fetch retry:** when the master's waveform is missing, the fetch is retried after 12, 24 and
  48 s, then every 60 s (before: grid only until the next track).
- **CDJ-3000 precise position (0x0b)** (`mods/link0b`): sent every 30 ms to CDJ-3000 and Cueline peers only (never
  to stock NXS2s, DJMs or rekordbox); a master's 0x0b feeds the meter. The 3000-format status (sent to 3000s only)
  sets byte 0xCD bit 0x20 so a CDJ-3000's WAVEFORM view draws a Cueline master's waveform (emulator, 3000 fw 3.22).
- **Zoom cache:** the neighbouring zoom levels are kept in a pool of hardware rings, so a zoom change shows in the
  same frame. At the two widest zooms only bar lines are drawn (less flicker, as on the CDJ-3000).
- **WAVEFORM FULL / HALF** now applies to 3BAND too; FULL (default) = drawn up from the bottom at full height,
  HALF = mirrored (the meaning of the two labels is swapped against v4.0.0). The UTILITY / SHORT CUT preview
  strip updates live.
- **Fixes:** TRACK SEARCH on a paused deck could leave the waveform / time undrawn until PLAY; stale pixels after a
  needle search or CUE on a paused deck (needle fix); D-cache purge of the GR3 buffers after each frame against
  artefacts after loads (`-DV2_G3PURGE`); faster bottom time display.
- **KEY SHIFT engine ks3:** cleaner splices and a ~12 ms glide when the amount changes.
- **RELEASE:** the kill switches are no longer shown in UTILITY (they stay ON; DEV keeps them, plus the new
  LINK 0x0B switch); the UTILITY header and boot line read "Cueline"; UTILITY > BUILD shows `Cueline-1.89 <hash>`.
- **Versioning:** Cueline now uses the deck's version labels: this beta is MAIN 1.89 / GUI 1.83 (DEV and RELEASE
  alike); 2.0 follows. Install after UTILITY > DUPLICATION > DEFAULT (LAN cable disconnected).

## v4.0.0 -- 2026-11-17: RELEASE `V4r8` / DEV `V4n44` (first public test release; withdrawn, replaced by 1.89 beta)
- Fixes and polish after V4r2 / V4n38 (emulator-verified; per-change notes are in the source headers of `mods/`).
- **Languages:** the deck's menus keep only English and Spanish (`lang2`: the 16 other stock menu languages
  removed; `guitrim_cjk`: the Chinese and Korean font banks; `reclaim`: the non-Latin text code pages), to free
  firmware space for the new features. For another menu language, stay on the official firmware.

## V4r2 / V4n38 -- 2026-11-16 (bump 421 / 420, source hash `4e0038b8`)
- **Two build profiles** from one tree (`PROFILE=release|dev ./build.sh`): RELEASE has every feature and no test
  tooling (nothing on UDP 50098/50099, no autotest / HUD / TEST LOG); DEV adds the tooling (`dev/DEV_TOOLS.md`).
  A release build refuses dev flags / mods.
- **WAVEFORM FULL / HALF** (UTILITY > DISPLAY): now sets the overview strip and the browse rows' mini waveforms
  (mirrored / upward; default FULL since the latest builds, HALF before); the detail band is always the mirrored 3000 waveform (deck feedback
  on V4n37).
- **BLACK BOX** event recorder (MENU + BACK 3 s -> `C:/BLACKBOX.BIN`, automatic dumps on errors; DEV also streams
  it on the RED log) + its kill switch (8th).
- **KEY SYNC with CDJ-3000s**: our status packet carries the 3000 key fields (0x180 bytes, 0x124 = 1, 0x16C = 1,
  KEY SHIFT in 0x164, sounding key in 0x15C without our KEY SHIFT); a 3000 master's KEY SHIFT is followed.
- **KEY FORMAT** CLASSIC / ALPHANUMERIC everywhere.
- **MENU / SHORTCUT / INFO 60 fps** (emulator 30 / 30 / 4 before), close-path glitch fixed.
- **Traceability**: UTILITY > BUILD, build record at 0x08014180, `cmd.py ver`, BUILDS.tsv; **kill switches**
  (LINK KEY STATUS, KEY SYNC, LINK CUE, MASTER WAVE NFS, MASTER WAVEFORM, HW BAND LAYER, LINK ROW PREVIEW,
  BLACK BOX); RED-log HUD capture fixed (GUI records taken before MAIN clears the RX slot).
- MAIN room: lang2 block moved 0x08017000 -> 0x08017C00 (UTILITY table grew to 42 / 43 items).
- Not in these builds: jogcue (cue-marker blink on the jog centre) and jogtest.

## V4n25 .. V4n35 (2026-11-13 / 14)
- **6 zooms** (the 3000's sixth level), **slip ghost**, **HOT CUE COLOR** honoured, **UTILITY help texts**,
  **SOURCE list** for the LINK key, LOAD button on the selected browse row, **tempo takeover** arrow after SYNC
  off, network commander + RED log for the rig (`cmd.py`), real-rig plans (solo / two decks / KEY SYNC / Link
  Cue). V4n35: all real-rig plans PASS on the author's decks.

## V4a .. V4n24 = RC1 (2026-11-11 / 13)
- Waveform band on the **VDC4 hardware layer GR2** (2-ring buffer, chroma key on GR3): 59-60 fps on the deck;
  1-px steps by moving the GR2 window (the real VDC4 ignores STA_POS); whole-pixel zooms 1-2.
- **Master WAVEFORM** view in the phase meter (the master's PWV5 + PQT2 over Pro DJ Link, message 0x31).
- **KEY SHIFT** front end, **KEY SYNC**, KEY SYNC BUTTON on pad D/H, CDJ-3000 master key from its status packet
  (`ks3k`) -- in our own builds; see the README for this package.
- Artwork on the MAIN JPU with a software fallback, cue colours + comments, CONTINUE auto-load follow-up.
- `reclaim` / `guitrim_cjk`: MAIN and GUI room (GUI ~2.9 MB under stock).

## V3 (2026-11-05 / 11)
- Our own GUI renderer (`mods/v2ui`) for every screen we own in CDJ-3000 layouts; Day Mode; EN/ES only (`lang2`).
- No-analysis tracks show nothing analysis-derived; WAVEFORM COLOR; overview / overlays / playhead.
- Touch: drag + momentum, pads, beat loop / beat jump. Link Cue to the DJM-A9, WAV 32-bit, Players 5/6.
- **Update-mode safety rule** after the V3 update race: every MAIN mod gated on `*0x0A35DF3C == 1`; the
  permanent racegate on every build for the deck.

# Cueline 2.1

> [!NOTE]
> **Stable release:** tested in our emulator and confirmed on real CDJ-2000NXS2 decks (two decks on Pro DJ Link,
> including an autonomous test run and the settings power-cycle check). Keep the official 1.87 update to go back to
> stock, and test at home before a gig.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.1 = MAIN 2.10 / GUI 2.04. Coming from 1.92 beta: same
install steps (the factory reset is recommended; it is required coming from a DEV build or any build with a higher
version number). Your Cueline settings saved by 1.92 are carried over.

## Get it
No firmware file is attached. You build Cueline yourself from **your own official CDJ-2000NXS2 update 1.87**
(`C2KNXS2.UPD`, sha256 `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5`):
- **EASY — in your browser:** [Cueline Web Builder](https://feers77.github.io/cueline/webbuilder/). Drop your `C2KNXS2.UPD`, click Download. Nothing to
  install; your file never leaves your computer.
- **Windows:** download `CuelineBuilder.exe` below and drag your `C2KNXS2.UPD` onto it.
- **macOS:** download `CuelineBuilder-macOS.zip` below (Intel and Apple Silicon), unzip, drag your `C2KNXS2.UPD`
  onto `CuelineBuilder.app`. First time: System Settings → Privacy & Security → **Open Anyway** (the app is not
  notarized). See README → *Easy install on macOS*.
- **Linux:** `python3 builder/cueline_patch.py /path/to/C2KNXS2.UPD` (from the source code, Python 3).
- **From source:** `./build.sh /path/to/C2KNXS2.UPD` (see the README).

All of them give the same file:
- `C2KNXS2.UPD` sha256 `3b85d55f05052ad0cc376a807114d6bf218be2d50483c0038b1d66afcbb5cd23`
- device version MAIN 2.10 / GUI 2.04; UTILITY → INFO → BUILD shows `Cueline-2.1 e2a70b09`

## Install (read this)
1. Save MY SETTINGS with rekordbox and note your deck settings: the next step erases them.
2. **Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION →
   DEFAULT.** Then **UTILITY → DUPLICATION → DEFAULT** (factory reset). Required if the deck had a DEV build, a build
   with a higher version number or any other custom build (otherwise the update is skipped); recommended always.
3. Copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and install it like an official
   update. **Never switch the deck off during the update.**
4. Check UTILITY → INFO → BUILD = `Cueline-2.1 e2a70b09`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.1 (since 1.92 beta)
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

Full history: CHANGELOG.md.

## Known limits (short)
- The WAVEFORM meter may sit 1 pixel row off vertically. The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some settings are kept only with a HISTORY NAME of 29 characters or fewer (docs/KNOWN_LIMITS.md).
- Downgrading to 1.92 keeps your settings except WAVEFORM HALF (it reads as FULL).
- Link Cue needs a DJM-A9 and plays MP3 / FLAC / WAV only.
- Menus in English and Spanish only. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `decce828bcf59ef972ec2ee7e69f8c191e8823bd6407a3ce54eecc4f5f60eada` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `9fd5d5af7ad883e5bae6daa6c2e962e7de36b809d409709857ff46d50037637d` |
| `cueline.delta` (patch data, also in `builder/`) | `89230d1afbd6bad2b11432c953779cd087596cc425fcea4091b97aeccda37344` |
| Your built `C2KNXS2.UPD` (expected output) | `3b85d55f05052ad0cc376a807114d6bf218be2d50483c0038b1d66afcbb5cd23` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).

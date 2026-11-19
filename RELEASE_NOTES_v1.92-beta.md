# Cueline 1.92 beta (2.0 release candidate)

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.

> 🧪 **BETA / PRE-RELEASE.** This is the release candidate of Cueline 2.0. It has been tested on our own decks and
> in our test environment, but it **may contain bugs**. **Test it at home before you take it to a gig**, keep the
> official 1.87 update on a USB stick to go back to stock, and play anything that matters with the official
> firmware if in doubt. Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty.
> **Not affiliated with or endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 1.92 beta → 2.0. Coming from an earlier Cueline beta: same install
steps (the factory reset is recommended; it is required coming from an earlier test build with a higher version
number or a DEV build).

## Get it
No firmware file is attached. You build Cueline yourself from **your own official CDJ-2000NXS2 update 1.87**
(`C2KNXS2.UPD`, sha256 `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5`):
- **Windows:** download `CuelineBuilder.exe` below and drag your `C2KNXS2.UPD` onto it.
- **macOS / Linux:** `python3 builder/cueline_patch.py /path/to/C2KNXS2.UPD` (from the source code, Python 3).
- **From source:** `./build.sh /path/to/C2KNXS2.UPD` (see the README).

All three give the same file:
- `C2KNXS2.UPD` sha256 `91eca696ff991006aed81dfdb30a9d2fec16c045fd56fb8922b720aebeb78223`
- device version MAIN 1.92 / GUI 1.86; UTILITY → INFO → BUILD shows `Cueline-1.92 c5e8e0f3`

## Install (read this)
1. Save MY SETTINGS with rekordbox and note your deck settings: the next step erases them.
2. **Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION →
   DEFAULT.** Then **UTILITY → DUPLICATION → DEFAULT** (factory reset). Required if the deck had an earlier test build with a higher version number, a DEV build or
   any other custom build (otherwise the update is skipped); recommended always.
3. Copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and install it like an official
   update. **Never switch the deck off during the update.**
4. Check UTILITY → INFO → BUILD = `Cueline-1.92 c5e8e0f3`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Details: README → *Going back to stock*.

## New in 1.92 beta
- **MY SETTINGS now loads from USB again (bug fix):** inserting a USB stick that holds your rekordbox MY SETTINGS
  makes the deck offer its own "MY SETTINGS" LOAD dialog. On earlier betas that stock dialog was hidden behind the
  Cueline screen as a black box, so its LOAD button could not be pressed and the settings never loaded. The dialog
  is now shown by the deck in its normal place with its button working. Your deck's own menus — TAG LIST, SORT,
  LIST MENU, LOAD PREVIOUS TRACK — are drawn exactly as before.
- **Versioning:** MAIN 1.92 / GUI 1.86 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-1.92 <hash>`.

Earlier changes (LINK meter on hardware layers, LINK OFFSET, CDJ-3000 0x0b / waveform, zoom cache, fixes): see
CHANGELOG.md.

## Known limits (short)
- The WAVEFORM meter may sit 1 pixel row off vertically.
- The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some fixes in this beta come from reading the code (our emulator could not reproduce the bug): tell us if you
  still see them.
- Menus in English and Spanish only. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `8f1d5c96a8c5d1365c97346e6e687321cfeb675acfb0ca8ed7602f6a7db87c70` |
| `cueline.delta` (patch data, also in `builder/`) | `a4ed8c974ae7b5015d888208f2432874d0a8e0e4bcd88f16409b6930168da992` |
| `SHA256SUMS.txt` | the checksums above, plus input and expected output |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Fixes and features are welcome as pull requests (CONTRIBUTING.md).

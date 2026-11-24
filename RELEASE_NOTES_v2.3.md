# Cueline 2.3

**KEY SHIFT and KEY SYNC are back.** 2.3 brings them back with a new engine that works inside the deck's own
MASTER TEMPO engine, as the CDJ-3000 does: about 0.4 ms of added delay, exact tempo and position, −12 … +11
semitones, with MASTER TEMPO on or off.

**It also fixes a display freeze that 2.2 has:** on real decks the screen stopped for about 2½ minutes whenever a
loop became active on the player screen (audio and keys kept working). **If you run 2.2 or anything older, update
to 2.3.**

2.3 was confirmed on two real CDJ-2000NXS2 decks on Pro DJ Link with an unattended 35-minute test script (key
shifts, loops, searches and screen changes on eight long tracks) on a developer build of the same sources.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.3 = MAIN 2.20 / GUI 2.14. **Coming from 2.2, 2.1 or 2.1.1
you do not need a factory reset** (MAIN 2.20 is newer, so the deck installs it). Coming from a build with
the same or a higher version number (a DEV build, another custom firmware), do **UTILITY → DUPLICATION → DEFAULT**
first, or the update is skipped. Your Cueline settings are carried over.

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
- `C2KNXS2.UPD` sha256 `85905736d2f042e3be62c363180c60a5107d97032fa854369c28315074ca0b6e`
- device version MAIN 2.20 / GUI 2.14; UTILITY → INFO → BUILD shows `Cueline-2.3 2cd1c93f`

## Install (read this)
1. **Coming from the official firmware, Cueline 2.2, 2.1 or 2.1.1:** copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and
   install it like an official update. No factory reset, your settings stay. **Never switch the deck off during the
   update.**
2. **Coming from anything with the same or a higher version number** (a DEV build, another custom firmware), or if
   the deck skips the update: save MY SETTINGS with rekordbox and note your deck settings, **disconnect the Pro DJ
   Link (LAN) cable** (while LINK is active the player does not allow DUPLICATION → DEFAULT), do **UTILITY →
   DUPLICATION → DEFAULT** (factory reset, it erases your settings) and install again.
3. Check UTILITY → INFO → BUILD = `Cueline-2.3 2cd1c93f`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.3 (since 2.2)
- **KEY SHIFT is back, with a new engine.** It now works *inside* the deck's own MASTER TEMPO engine, the way the
  CDJ-3000 does it: the original time-stretcher runs at tempo ÷ pitch and its output is resampled by the pitch
  ratio. No separate pitch shifter after the audio path any more, so the added delay is about 0.4 ms instead of the
  0.7–33 ms sawtooth of the 2.1 engine, and the "doubled" hi-hats are gone. Range −12 … +11 semitones. It works with
  MASTER TEMPO on **or off** (with it off the tempo fader still changes the pitch as usual, plus your shift), without
  touching the MASTER TEMPO key. Tempo and position stay exact (measured on real decks: 993–1010 ms of track per
  second at every shift).
- **KEY SYNC and the KEY SYNC BUTTON are back** in UTILITY and use the same engine.
- **Screen frozen for about 2½ minutes when a loop became active (bug fix, also present in 2.2):** on real decks,
  LOOP OUT or the 4-beat loop key on the player screen stopped the display (audio and keys kept working) and it
  came back by itself minutes later. The original firmware was still drawing its own hidden loop-shading window,
  one slow hardware copy per row. Cueline draws the loop itself, so that window is no longer drawn at all.
- **Seven menu languages again:** LANGUAGE offers English, French, German, Italian, Dutch, Spanish and Portuguese
  for the deck's own texts. Cueline's own screens stay in English.
- **Tested on real decks:** two CDJ-2000NXS2 on Pro DJ Link ran a 35-minute unattended script on a developer build
  of the same sources: eight long tracks (WAV 24, M4A, WAV 32 float, MP3, FLAC), three passes each with +4 and −5,
  MASTER TEMPO toggled every pass, a loop, a search and CUE / PLAY in every pass, then a long loop with SYNC,
  MASTER, BROWSE and SHORT CUT inside it. The screen was painted every second throughout; no EMERGENCY LOOP.
- **Versioning:** MAIN 2.20 / GUI 2.14 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-2.3 <hash>`.
  2.3 installs over 2.2, 2.1.1 and 2.1 without a factory reset.

Everything else from 2.2 is unchanged. Full history: CHANGELOG.md.

## Known limits (short)
- KEY SHIFT has no effect on tracks of 48 / 88.2 / 96 kHz (they play unshifted); 44.1 kHz tracks only for now.
- KEY SYNC with the new engine and the menu languages were checked in the emulator, not yet measured on real decks.
- The first preview over LINK from another deck's USB can take a moment; after that it is immediate.
- Two Cueline decks sharing the mixer's Link Monitor: the hand-over takes a moment, so the monitor starts with a
  short delay, and holding a preview on both decks at once can still interleave the audio for a few seconds. Both
  are being improved in a later release.
- The WAVEFORM meter may sit 1 pixel row off vertically. The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some settings are kept only with a HISTORY NAME of 29 characters or fewer (docs/KNOWN_LIMITS.md).
- Link Cue needs a DJM-A9 and plays MP3 / FLAC / WAV only.
- The deck's own menus come in seven languages; Cueline's own screens are in English. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `b1d99409c6adca1176dae1cf03c138e74691a9b5f719b3749d40ec251f0dc641` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `322a57ebf1c3bc3a75225a3e5ce19d49cfe37a6b1328da2ab198d0d179b86894` |
| `cueline.delta` (patch data, also in `builder/`) | `cbbabcba2eb62714aa0ff2232ee374be46857d1698f789071d8fd82cbcf08632` |
| Your built `C2KNXS2.UPD` (expected output) | `85905736d2f042e3be62c363180c60a5107d97032fa854369c28315074ca0b6e` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).

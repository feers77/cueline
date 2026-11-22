# Contributing to Cueline

Thanks for helping. Cueline is a custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
It is built from the user's own official update file. This page explains how to set up, build, test and send
changes. The developer documentation is in `docs/dev/`:

| file | what |
|---|---|
| `docs/dev/ARCHITECTURE.md` | the three CPUs, how mods are placed, the MAIN <-> GUI channels, update safety |
| `docs/dev/BUILD_PIPELINE.md` | what `build.sh` does, step by step |
| `docs/dev/MODS.md` | every mod in the RELEASE and DEV recipes |
| `docs/dev/TESTING.md` | gates, deck tests, logs, black box, commander |
| `docs/dev/HOWTO.md` | how to add a UTILITY item, a screen, a DSP feature; the release process |
| `dev/README.md` | the DEV build and the developer tools |
| `docs/TECHNICAL_OVERVIEW.md` | the long technical reference |

## 1. Ground rules (read first)

- **Never commit Pioneer DJ / AlphaTheta bytes.** No `.UPD`, no decoded images, no flash dumps, no
  disassembly, no extracted fonts, icons or strings. Everything that comes from the stock firmware is
  regenerated from the user's own `.UPD` at build time (for example the players 5/6 call-site tables).
- **No CDJ-3000 firmware content.** No code, data, symbol names, class names or addresses taken from any
  CDJ-3000 firmware. We copy the 3000's *look and behaviour* (what a user sees and what goes over the network),
  never its firmware. Pro DJ Link packet layouts observed on the wire are fine.
- **No binaries in pull requests.** Sources only. Every output must be reproducible from the sources and the
  official 1.87 update. The one exception is the prebuilt DSP image of our Key Shift engine in `mods/ownks/dsp/`
  (our code only): change it only together with its C sources, built with the toolchain from `build_toolchain.sh`.
- **Never flash anything for someone else.** A contributor builds and tests on their own deck, at their own risk.

## 2. Setup

Reference system: Ubuntu 24.04 (native or WSL on Windows 10/11). On macOS use a Linux VM or a Docker
`ubuntu:24.04` container (the SH cross-compiler is not packaged for macOS).

```
sudo apt install gcc-sh4-linux-gnu binutils-sh4-linux-gnu python3-pil python3-numpy python3-fonttools
```

- Check: `sh4-linux-gnu-gcc --version` (reference 13.3.0) and `python3 -c "import PIL, numpy, fontTools"`.
- On WSL, keep the clone in the Linux file system (for example `~/cueline`), not on the Windows drive.
- **Optional:** a `tic6x-elf` toolchain (binutils 2.42 + gcc 13.2, C only). You need it only to rebuild the DSP
  image of our Key Shift engine. See `mods/ownks/dsp/` (`build_toolchain.sh`, then `build.sh`; the tools are
  found through the `CDJ_TIC6X` environment variable). Without it, the build uses the DSP image committed in
  `mods/ownks/dsp/`.
- The input: the official `C2KNXS2.UPD` **1.87** (MAIN 1.87 / GUI 1.81). Download it yourself from Pioneer DJ.
  `build.sh` checks its sha256 and refuses any other file. Keep it unmodified: it is also your way back to stock.

## 3. Build

```
./build.sh C2KNXS2.UPD                     # RELEASE  -> out-release/C2KNXS2.UPD  (= R22R2r)
PROFILE=dev ./build.sh C2KNXS2.UPD         # DEV      -> out-dev/C2KNXS2.UPD      (= R22R2n)
```

- Both profiles build from the same sources. DEV also copies `dev/mods/` into the build's work copy and adds
  the test tooling (see `dev/README.md`).
- `build.sh` works in a scratch copy (`out-<profile>/work`, removed at the end), so the tree stays clean.
- Outputs: `C2KNXS2.UPD`, `build.log`, `verify.txt`, `bootcheck.txt`.
- Exit code: 0 = byte-identical to the reference; 2 = built and checked, but the sha256 differs (other tool
  versions or edited sources); 1 = error. **Never install a build whose verify or boot check failed.**
- Edited sources give a local build ID (`<TAG>m <date> <source hash>`), shown in UTILITY > INFO > BUILD.

## 4. The gates

Every build must pass these before it goes near a deck.

1. **`verify_update`** (`scripts/firmware/verify_update.py`, run by `build.sh` into `verify.txt`). It re-reads the
   output the way the deck's updater does: container and labels, every CRC and checksum, the MAIN byte sum,
   the untouched sections (DRIV, PANL, bootloader and emergency updater S-records) byte-identical to stock, and
   the decoded images equal to what the patchers produce for the same mod list.
2. **`gui_bootcheck --strict`** (`scripts/firmware/gui_bootcheck.py`, into `bootcheck.txt`). A static model of what
   the GUI bootloader needs: section header, CRCs, lengths, the scatter-load chain, the image trailer, the
   artwork and font archives.
3. **Racegate (concept).** Maintainers run every candidate through the update path twice in an emulator: once
   with a small rescue update and once with the official 1.87. The build is modified so that the mod task is
   forced to spawn early (the worst order). PASS means: no CPU reset, the mod task never starts in update mode,
   and the updater reaches its normal file states. Our emulator is not part of this repository. If you change
   anything that runs at boot, say so in the pull request so a maintainer can run it.

## 5. Real-deck testing

- Install from **stock** with a **small, fast FAT32 stick** holding only the `.UPD`. Use a UPS if you can.
  Never power off during an update.
- Test plans for one or more decks on Pro DJ Link are in `dev/tools/rig/plans/` (run with
  `dev/tools/rig/rig.py`; see `dev/DEV_TOOLS.md`). They need the DEV build.
- Test at home, never at a gig. Write down what you tested (see section 9).
- Back to stock: disconnect the LAN cable, UTILITY > DUPLICATION > DEFAULT, then the official 1.87 (see `docs/back_to_stock.txt`).

## 6. Coding rules (learned the hard way)

1. **The boot-state gate.** Every MAIN mod that counts, allocates (`malloc`), spawns a task or installs a hook
   must do nothing unless the boot-state word `*0x0A35DF3C == 1` (normal boot; 2 = update mode). Literal-redirect
   stubs test it **on every call**, not once. In update mode the stock updater rebuilds the heap; a task started
   from the old heap once overwrote the update buffer on slow sticks. See `docs/dev/ARCHITECTURE.md`.
2. **GUI size.** The patched GUI section must stay at or below the stock GUI section size. Make room by trimming
   (languages, unused glyph banks: `mods/guitrim/`), never by growing past stock.
3. **Never touch the update screen.** The installed GUI draws update mode. No GUI timing pokes, no drawing while
   the GUI's update state is set. One timing poke once broke update mode on a real deck.
4. **Labels and version bump.** The deck's updater writes a section only when its label is *newer* than the
   installed one (a `+` suffix does not count). Every build gets `--main-bump=N --gui-bump=N` (each label = the stock
   section label + N/100; MAIN 1.87 + N/100).
   That is why going back to stock needs **UTILITY > DUPLICATION > DEFAULT** first: the factory reset clears the
   installed label, so the official 1.87 is newer again. `build.sh` uses the reference bump of each profile, so
   a local build has the same label as the one already installed and would be skipped: install it from stock, or
   do the DEFAULT reset first.
5. **No Pioneer bytes, no CDJ-3000 content.** See section 1. Stock-derived data is generated at build time from the
   user's `.UPD` and is never committed.
6. **MAIN mods are assembled, not linked.** Never write `.long own_label` in a MAIN `.s` file. Use `mova` or
   PC-relative addressing. Check every literal you redirect still holds its stock value (`patch_main.py` does this
   for the tables it knows).
7. **Saved settings.** Settings byte 6 bit 0 is stock's "invalid record" flag. Never store anything there.
8. **Physical checks before blaming firmware.** Before you report a firmware bug, rule out the setup: the stick
   (format, speed, an old `PIONEER` folder from another export), cables and the LINK switch, power, and the
   rekordbox export. Several "firmware bugs" in this project were a slow stick or stale data on the stick.
9. **The emulator is not the deck.** Panel latch timing, the VDC4 scroll registers and LED colours behaved
   differently on the real deck. Only a deck test proves a display or timing change.

## 7. Reporting bugs

1. Note **UTILITY > INFO > BUILD**, your setup (decks, mixer, Pro DJ Link or not) and the file format.
2. If you can, reproduce it with the **DEV build** (`PROFILE=dev ./build.sh ...`) and use its **BLACK BOX**: right
   after the problem, with the deck stopped and the stick in, hold **MENU + BACK for 3 seconds**. The deck appends
   a dump to `BLACKBOX.BIN` on the stick (the last 512 deck events and a state snapshot).
3. Decode it: `python3 dev/tools/bbox/decode_bbox.py BLACKBOX.BIN [--last]`.
4. Open a GitHub issue with the **Bug report** template (`.github/ISSUE_TEMPLATE/bug_report.md`): BUILD id,
   profile (RELEASE / DEV), your LINK setup and other gear (stock NXS2, CDJ-3000, DJM, rekordbox), steps, expected
   vs actual, media / format, photos or video, and `BLACKBOX.BIN` from a DEV build. Say which kill switch
   (UTILITY > INFO) makes it go away, if any. Ideas go in a **Feature request** issue.

The RELEASE build has no black box, no logs and no network commander.

## 8. Pull requests

This is a community testing project: fixes and features are welcome. Pull requests are reviewed here and what
works is merged. The pull request template (`.github/PULL_REQUEST_TEMPLATE.md`) has the checklist below:

- **One feature or fix per pull request.**
- Both gates pass for RELEASE **and** DEV (`verify.txt` ends with `all checks passed`, `bootcheck.txt` starts with
  `PASS`). Paste both lines.
- **Describe your deck tests:** deck(s), mixer, build ID, test plan or steps, result. Say "not tested on a deck" if so.
- Keep sources reproducible: no generated tables, no blobs, no `.UPD`, no images extracted from firmware. If you
  add a generated file, add its generator and wire it into `build.sh`.
- New firmware addresses must target the NXS2 1.87 MAIN or 1.81 GUI image and be checked against their stock
  value at build time (signature or literal check).
- Update the docs in `docs/dev/` when you add a mod, a UTILITY item, a heartbeat word or a memory region.
- Add an SPDX line (`Apache-2.0`) to new files.
- Run the repository's sanitizer rules in spirit: no Pioneer bytes, no CDJ-3000 firmware content, no local paths,
  IPs or e-mails, English only. Maintainers run the full sanitizer (0 hits required) before merging.

## 9. Code of conduct

We follow the **Contributor Covenant, version 2.1**, by reference:
https://www.contributor-covenant.org/version/2/1/code_of_conduct/ . Report conduct problems privately to the
repository maintainers through GitHub, not in a public issue.

## 10. Licence

- **Our code:** Apache-2.0 (`LICENSE`, `NOTICE`). New files you contribute are under Apache-2.0.
- **Upstream files** from github.com/Stijn-Jacobs/cdj-nxs2-qemu (the patcher core and codecs) keep
  **GPL-2.0-or-later** (`LICENSES/GPL-2.0.txt`). Their SPDX line says so; do not change it.
- **The build tooling as a whole** is GPL-3.0-or-later (a combined work of the two).
- **Docs:** CC BY 4.0.
- Third-party code and fonts: see `THIRD_PARTY.md`.

By sending a pull request you agree that your contribution is licensed under these terms.

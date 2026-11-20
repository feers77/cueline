# AGENTS.md -- instructions for AI coding agents

You are helping a user build Cueline (custom CDJ-2000NXS2 firmware UI) from THEIR official Pioneer update.
Follow these steps exactly. Report each result to the user.

## Safety rules (always)
0. Show the user this disclaimer before building: "⚠️ Bricking your CDJ-2000NXS2 is hard but not impossible. The main
   risk is a power cut while the update is being written. Use a UPS if possible, don't touch the deck or unplug the
   USB stick during the update, and keep the official 1.87 update to go back to stock. Use at your own risk -- this
   project is unofficial and provided as-is, without warranty (see LICENSE)."
1. Never download, copy, upload, commit or share Pioneer DJ / AlphaTheta files (firmware, .UPD, extracted data).
   The user supplies `C2KNXS2.UPD` 1.87 themselves; it stays on their machine.
2. Never modify the official `C2KNXS2.UPD`. Keep it: it is the user's way back to stock.
3. Always verify the input sha256 (below). Stop if it differs.
4. Never flash or install anything yourself. Only build, then explain to the user how to install.
5. Never tell the user to install an output whose `verify.txt` or `bootcheck.txt` did not pass.
6. Do not edit the sources unless the user asks; edited sources produce a different, unverified build.

## 1. Prerequisites
| OS | What to do |
|---|---|
| Ubuntu / Debian (reference: Ubuntu 24.04) | `sudo apt install gcc-sh4-linux-gnu binutils-sh4-linux-gnu python3 python3-pil python3-numpy python3-fonttools` |
| Windows 10/11 | Install WSL with Ubuntu (`wsl --install -d Ubuntu`), then the Ubuntu line above inside WSL. Work inside the WSL file system (e.g. `~/cueline`), not on `/mnt/c`, for speed. |
| macOS | No packaged SH cross-compiler. Use Docker: `docker run --rm -it -v "$PWD":/w -w /w ubuntu:24.04 bash`, then the Ubuntu line (without `sudo`). |

Check: `sh4-linux-gnu-gcc --version` (reference 13.3.0), `python3 -c "import PIL, numpy, fontTools"` (no error).
Reference versions: binutils 2.42, Python 3.12, Pillow 12.1.1, fontTools 4.61.1.

## 2. Input
- Ask the user for the path to their official `C2KNXS2.UPD` (CDJ-2000NXS2 firmware 1.87, from Pioneer DJ).
- Verify: `sha256sum C2KNXS2.UPD` must print
  `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5`.
  If not: it is not the official 1.87 (other version, modified, or still zipped). Ask the user to download it again.

## 3a. Easy path: Cueline Builder (no compilers)
```
python3 builder/cueline_patch.py /path/to/C2KNXS2.UPD          # writes Cueline/C2KNXS2.UPD next to the input
```
It verifies the input sha256, applies `builder/cueline.delta` (our prebuilt patch data; `builder/cueline.delta`
sha256 `89230d1afbd6bad2b11432c953779cd087596cc425fcea4091b97aeccda37344`), repacks, and checks the output sha256 equals `3b85d55f05052ad0cc376a807114d6bf218be2d50483c0038b1d66afcbb5cd23`. On Windows the same tool is
`CuelineBuilder.exe` (release asset, sha256 `decce828bcf59ef972ec2ee7e69f8c191e8823bd6407a3ce54eecc4f5f60eada`; unsigned: SmartScreen may warn). On macOS it is `CuelineBuilder-macOS.zip` (release asset, sha256 `9fd5d5af7ad883e5bae6daa6c2e962e7de36b809d409709857ff46d50037637d`; universal app, not notarized: the first time, System Settings -> Privacy & Security -> Open Anyway). In a browser: the Cueline Web Builder (https://feers77.github.io/cueline/webbuilder/), same output.

## 3. Build from source (paranoid path)
From the repository root:
```
./build.sh /path/to/C2KNXS2.UPD 
```
Takes a few minutes. Expected end of the output:
```
build.sh: wrote .../out-release/C2KNXS2.UPD  [profile release, build ID "Cueline-2.1 20261120-1459 e2a70b09"]
  sha256    3b85d55f05052ad0cc376a807114d6bf218be2d50483c0038b1d66afcbb5cd23
  verify    verify_update: all checks passed
  bootcheck PASS  ...
  == V4r21 reference build, byte-identical (sha256 3b85d55f05052ad0cc376a807114d6bf218be2d50483c0038b1d66afcbb5cd23)
```
Exit codes: 0 = identical to the reference; 2 = built and checked, but the sha differs (other tool versions:
acceptable if verify and bootcheck passed); 1 = error (do not install).

## 3b. DEV build (contributors only)
`PROFILE=dev ./build.sh /path/to/C2KNXS2.UPD` builds the DEV variant (dev/mods: BLACK BOX, logs, commander,
autotest). Only for testing; see dev/README.md.

## 4. Verify
- `tail -1 out-release/verify.txt` -> `verify_update: all checks passed`
- `head -1 out-release/bootcheck.txt` -> starts with `PASS`
- `sha256sum out-release/C2KNXS2.UPD` -> compare with the reference above and tell the user.

## 5. Tell the user how to install
1. Save MY SETTINGS with rekordbox if they use them (the next step erases the deck settings).
2. Disconnect the Pro DJ Link (LAN) cable (while LINK is active the player does not allow DUPLICATION -> DEFAULT),
   then UTILITY -> DUPLICATION -> DEFAULT (factory reset). This clears the installed version, so the update is not
   skipped (needed over any earlier Cueline build, recommended always).
3. Copy `out-release/C2KNXS2.UPD` alone to the root of a small FAT32 USB stick.
4. Deck off, insert the stick, start the update as in Pioneer's official CDJ-2000NXS2 update guide, wait for
   complete, power-cycle. Never switch off during the update.
5. UTILITY > INFO > BUILD shows `Cueline-2.1 e2a70b09`.
6. Tell them 2.1 is the current stable release (confirmed on real decks), but it is unofficial: test at home before a gig, keep the
   official 1.87 on a stick, report bugs in GitHub Issues.
7. Back to stock (explain all of it):
   a. Why: Cueline has a higher version number, so the deck skips the official 1.87 until the installed version is
      cleared.
   b. Disconnect the Pro DJ Link (LAN) cable (while LINK is active the player does not allow DUPLICATION ->
      DEFAULT), then UTILITY -> DUPLICATION -> DEFAULT (factory reset; it resets the deck settings: note them first).
   c. The official `C2KNXS2.UPD` 1.87 (sha256 above) alone on a FAT32 stick, installed like any official update;
      same power cautions.
   d. Check UTILITY > VERSION = 1.87. If the update was skipped, repeat the reset.

## Common errors and fixes
| Message | Fix |
|---|---|
| `is not the official C2KNXS2.UPD 1.87` | Wrong file or version; download 1.87 again, unzip. |
| `missing tool 'sh4-linux-gnu-...'` | Install the prerequisites (section 1). |
| `missing Python modules` | `sudo apt install python3-pil python3-numpy python3-fonttools` (or `pip install pillow numpy fonttools`). |
| `the sources differ from MANIFEST.txt` | Files were edited. `git checkout .` (or a fresh download) restores them. |
| `verify FAILED` / `GUI boot check FAILED` | Do not install. Report the issue with `build.log`. |
| Permission denied on `./build.sh` | `chmod +x build.sh` |
| Very slow on WSL | Move the folder into the WSL home directory. |

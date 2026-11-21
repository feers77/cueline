# Build pipeline

What `./build.sh` does, step by step. One script builds both profiles from the same sources:

```
./build.sh C2KNXS2.UPD                  # RELEASE (V4r211e)
PROFILE=dev ./build.sh C2KNXS2.UPD      # DEV (V4n211e)
./build.sh C2KNXS2.UPD --out DIR        # other output directory (default ./out-<profile>)
./build.sh C2KNXS2.UPD --no-keyshift    # a variant without KEY SHIFT / KEY SYNC (no reference sha)
```

Inputs: the official `C2KNXS2.UPD` 1.87, the repository sources, the fonts in `fonts/`. Nothing else is downloaded.
Outputs in `out-<profile>/`: `C2KNXS2.UPD`, `build.log`, `verify.txt`, `bootcheck.txt`.

## 0. Checks before building

1. **Input sha256.** The `.UPD` must be the official 1.87 (sha256 in `build.sh`). Anything else stops the build.
2. **Tools.** `sh4-linux-gnu-{gcc,as,ld,objcopy,nm,readelf}`, Python >= 3.8 with Pillow (FreeType), numpy, fontTools.
3. **Fonts.** The UI font and the fallback font are checked by sha256. Another font builds, with a warning, and the
   output sha will differ.
4. **Sources.** `MANIFEST.txt` lists the sha256 of every file. If `mods/` and `scripts/` match it, the build gets the
   **reference build ID**. Otherwise it gets a local one: `<TAG>m <YYYYMMDD-HHMM> <HASH8>`, where HASH8 is
   `patch_main.source_hash()` (sha256 over every `mods/` source, path and content).

## 1. Work copy

`mods/` and `scripts/` are copied into `out-<profile>/work`. For `PROFILE=dev` the contents of `dev/mods/` are copied
over it (autotest, usblog, bbox, the test variant of the Link Cue task). The work copy is deleted at the end.

## 2. Generated parts (from your `.UPD`, never committed)

| step | tool | result |
|---|---|---|
| tadec decoder blob | `mods/tadec/build.sh` (`BASE`, `ARENA_KB`, `OPT=O2`) | MP3 / FLAC / JPEG decoder linked at the layout's tadec address |
| decode stock MAIN | `scripts/firmware/main_decode.py C2KNXS2.UPD stock_main.bin` | the decoded MAIN image (temporary) |
| players 5/6 cave | `mods/player56/build.sh` with `STOCK_MAIN=` | `gen56.py` / `genui.py` find the call sites in *your* stock MAIN and generate the tables; `p56.bin` at 0x081C4000 |
| GUI icons | the icon step of `build.sh` | the GUI icon atlas (`mods/v2ui_assets/`); generated, not committed |

The GUI image is decoded inside the patcher with `scripts/firmware/gui_decode.py` (LZSS; GUI length field big-endian)
and MAIN with `scripts/firmware/main_decode.py` (Motorola S-records around the same LZSS codec,
`scripts/firmware/lzss_decode.py`).

## 3. Assemble the mods

```
python3 mods/patch_gui.py  --assemble      # every gui_*.s -> .bin
python3 mods/patch_main.py --assemble      # every main_*.s -> .bin (per layout)
```

Always assemble before patching. A stale `.bin` against its `.s` once produced a bad image;
`patch_update.check_committed_bins` guards against that.

## 4. The v2ui renderer

`mods/v2ui/build.sh` compiles `v2.c` + `entry.S` + the generated font (`fontgen.py`) + the icon atlas for the SH-2A
(`-m4-nofpu -mb -Os`, hot paths `-O2`), links at 0x1C050000 (read-only data at 0x0C700000), and checks with
`check_sh2a.py` that no instruction the SH-2A lacks was emitted. `V2_CFLAGS` selects features:

| profile | flags |
|---|---|
| RELEASE | `-DV2_DMACPY -DV2_VSPACE -DV2_BDIRECT -DV2_AUTO60 -DV2_HWBAND -DV2_KEYSHIFT` |
| DEV | the same + `-DV2_HUD -DV2_USBLOG` |

`CDJ_V2_FONTTRIM=1` keeps only the glyphs each text size draws (GUI room).

## 5. Patch the update

```
python3 mods/player56/build_upd.py C2KNXS2.UPD out/C2KNXS2.UPD <mods...> \
        --bump-gui --main-bump=N --gui-bump=N --no-main-size-check --p56=proven
```

- `mods/player56/build_upd.py` installs the players 5/6 patches into `mods/patch_update.py` and runs it.
- `patch_update.py`:
  1. splits the container (CRLF-decimal manifest, four sections);
  2. decodes GUI (section 1) and MAIN (section 3);
  3. applies every named mod per image in **one** `patch()` call, so they share one placement and cannot collide
     (`patch_gui.py`, `patch_main.py`, both on `sigpatch.py`);
  4. applies the container-level pseudo-mods: `lang2` (`mods/lang8.py`), `font3000` (`mods/font3000`),
     `v2ui` and `v2needle` (`mods/v2ui/v2ui.py`), `guitrim*` (`mods/guitrim`, last);
  5. re-encodes (`scripts/firmware/gui_encode.py`, `main_encode.py`, `lzss_encode.py`), fixes lengths, CRCs, the MAIN
     byte sum and the GUI image trailer (CRC-16 at 0x14FFFA);
  6. rewrites the labels and the manifest.
- A mod name may be a group from `mods/mods.conf` (for example `wav32`, `three_band`), which expands into its patches.
- Each mod declares the firmware versions it was checked on; others are refused.

### Labels and the bump

The updater (MAIN 0x084F30B8) writes a section only when its label `VerX.YY` is newer than the installed one.
`--main-bump=N --gui-bump=N` raises each section label by N/100 over the stock section label
(`patch_update.bumped()`). The stock GUI section label is not the GUI image version, so the two labels differ for
the same N (an earlier build: MAIN 3.29 / GUI 3.28). The images keep their
internal version string (`1.87+` in MAIN), which the deck announces on Pro DJ Link, so stock decks do not warn
about other firmware. Going back to stock needs UTILITY > DUPLICATION > DEFAULT (clears the installed label) before
the official 1.87.

## 6. Gates

```
python3 scripts/firmware/verify_update.py C2KNXS2.UPD out/C2KNXS2.UPD <same mods and flags>   > verify.txt
python3 scripts/firmware/gui_bootcheck.py --strict out/C2KNXS2.UPD                               > bootcheck.txt
```

- `verify_update`: container and labels; every CRC-16/XMODEM trailer, S-record checksum and the MAIN byte sum;
  DRIV, PANL, the bootloader / emergency-updater S-records and the S7 record identical to stock; the decoded images
  equal to what the patchers produce for the same mods; the packed MAIN fits.
- `gui_bootcheck --strict`: section header (byte 31 = '0', never '1', which would erase the GUI bootloader), CRC,
  lengths, the scatter-load chain (copies inside the image, real RAM destinations, no overlap, entry inside a copied
  segment), the trailer, the artwork and font archives.
- `build.sh` prints both results and the output sha256, and compares it with the reference.

## 7. Profiles: DEV vs RELEASE

| | RELEASE | DEV |
|---|---|---|
| MAIN mods | the feature recipe (`docs/dev/MODS.md`) | + `autotest usblog bbox` (Link Cue task -> `touchaudiot`) |
| GUI flags | feature flags | + `-DV2_HUD -DV2_USBLOG` |
| UTILITY | no TEST LOG row | TEST LOG (OFF / USB / RED) |
| network / logs | none | commander UDP 50098, RED log UDP 50099, USB log |
| BLACK BOX | none | yes |

Release guards: `CDJ_PROFILE=release` makes `build.sh` and `patch_main.patch()` refuse the DEV mods (`autotest`,
`usblog`, `touchaudiot`, `jogtest`) and the DEV GUI flags.

## 8. MANIFEST and build ID

- `MANIFEST.txt` (repository root) = sha256 of every file. `build.sh` uses it to know whether the sources are the
  published ones.
- The build ID is `TAG YYYYMMDD-HHMM HASH8`. `patch_main.fill_build_record` writes it into modsmenu's build record
  (block + 0x180, `BLD1` + ASCII ID, then the UTF-16 text UTILITY > INFO > BUILD shows: `TAG HASH8`).
- With the reference toolchain (`REF_TOOLS` in `build.sh`) and unchanged sources, the output is byte-identical to
  the reference: exit code 0.

## 9. Environment knobs you may meet

| variable | used by | meaning |
|---|---|---|
| `PROFILE` / `CDJ_PROFILE` | `build.sh` / `patch_main.build_profile()` | release or dev |
| `CDJ_BUILD_ID` | `patch_main.build_id()` | the build ID written into the image |
| `V2_CFLAGS` | `mods/v2ui/build.sh` | renderer feature flags |
| `CDJ_V2_FONTTRIM` | `mods/v2ui` | trim glyph sets |
| `CDJ_V2_TTF`, `CDJ_FONT3000_TTF`, `CDJ_FONT3000_FALLBACK` | `mods/v2ui`, `mods/font3000` | font overrides |
| `STOCK_MAIN` | `mods/player56/build.sh` | your decoded stock MAIN |
| `CDJ_TIC6X` | `mods/ownks/ownks.py` | the tic6x toolchain's `bin` directory (rebuild of the DSP image) |
| `CDJ_UT_DIAG=1` | `patch_main.py` | show the LINK CUE DIAG row (debug) |

`build.sh` unsets the debug knobs before building, so a reference build is not affected by your shell.

# Third-party and upstream parts

Everything not listed here is ours: **Apache-2.0** (`LICENSE`, `NOTICE`); docs CC BY 4.0.

## Upstream: CDJ-2000NXS2 emulator project (github.com/Stijn-Jacobs/cdj-nxs2-qemu)
GPL-2.0-or-later (`LICENSES/GPL-2.0.txt`). The patcher core and some mods started there; they keep their
licence and their SPDX headers, including our later changes to them. The emulator itself is not included.
**The build tooling as a whole is GPL-3.0-or-later (combined work); our own files are Apache-2.0**
(Apache-2.0 is compatible with GPL-3.0).

- `mods/ableton_link/README.md`
- `mods/ableton_link/main_abletonlink.s`
- `mods/ableton_link/main_abletonlinkpong.s`
- `mods/ableton_link/main_link_shared.inc`
- `mods/high_fps/README.md`
- `mods/live_clock/README.md`
- `mods/mods.conf`
- `mods/osc/README.md`
- `mods/osc/main_osc.s`
- `mods/osc/main_oscbeat.s`
- `mods/patch_gui.py`
- `mods/patch_main.py`
- `mods/patch_update.py`
- `mods/phrase/README.md`
- `mods/phrase/gui_phrase.s`
- `mods/phrase/main_phrasedata.s`
- `mods/phrase/main_phrasefetch.s`
- `mods/sigpatch.py`
- `mods/tcnet/README.md`
- `mods/tcnet/main_tcnet.s`
- `mods/tcnet/main_tcnet_shared.inc`
- `mods/tcnet/main_tcnetdata.s`
- `mods/tcnet/main_tcnettime.s`
- `mods/three_band/README.md`
- `mods/three_band/gui_wave3.s`
- `mods/three_band/gui_wave3ov.s`
- `mods/three_band/main_wave3data.s`
- `mods/three_band/main_wave3detail.s`
- `mods/three_band/main_wave3ovdata.s`
- `mods/three_band/main_wave3ovfetch.s`
- `mods/usb_midi/README.md`
- `mods/usb_midi/main_usbmidi.s`
- `mods/usb_midi/main_usbmiditick.s`
- `scripts/firmware/gui_decode.py`
- `scripts/firmware/gui_encode.py`
- `scripts/firmware/lzss_decode.py`
- `scripts/firmware/lzss_encode.py`
- `scripts/firmware/main_decode.py`
- `scripts/firmware/main_encode.py`
- `scripts/firmware/make_flash.py`

## Ours, inside upstream mod directories (kept GPL-2.0-or-later, conservatively, as possibly derived)
- `mods/three_band/gui_wave3rgb.s`
- `mods/three_band/main_wave3ovrgb.s`

## Vendored code
- `mods/tadec/dr_mp3.h`, `mods/tadec/dr_flac.h` (David Reid) and `mods/tadec/stb_image.h` (Sean Barrett):
  public domain (Unlicense) or MIT-0, at your choice, as stated in each header.
- `dev/tools/rig/stagehand.py`: port of chrisle/alphatheta-connect (fork of EvanPurkhiser/prolink-connect), MIT,
  `dev/tools/rig/LICENSE.alphatheta-connect`.

## Fonts (`fonts/`)
- Roboto Condensed Regular 2.001047 (Google): Apache License 2.0, `fonts/LICENSE-RobotoCondensed.txt`.
- Not included: any Pioneer/AlphaTheta font.

## Built from the user's own copies at build time (never shipped)
- The official CDJ-2000NXS2 1.87 update (`C2KNXS2.UPD`) and everything derived from it.
- The stock NXS2 icons used next to our own icon set (taken from the same official 1.87 update).

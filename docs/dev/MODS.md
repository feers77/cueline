# Mods

Every mod in the RELEASE and DEV recipes: purpose, entry points, files. The recipe itself is in `build.sh`
(`FEAT_MODS`, `EXTRA_MODS`, `KS_*`). A name in the list may be a single patch (`python3 mods/patch_main.py --list`,
`python3 mods/patch_gui.py --list`), a group from `mods/mods.conf`, or a container-level pseudo-mod of
`mods/patch_update.py`. Addresses are NXS2 MAIN 1.87 / GUI 1.81, `ks` layout.

## The recipes

| profile | MAIN / GUI mod list (in build order) |
|---|---|
| RELEASE (R22R2r) | `touchaudio touchaudioip touchaudiotouch tadec modsmenu wav32 rowwave three_band ui3000x bootname font3000 v2ui v2needle lang2 usbkey keyshift reclaim guitrim_cjk w8send w8cap w8recv ks3k ownks` + players 5/6 (`--p56=proven`) |
| DEV (R22R2n) | the same + `autotest usblog` (after `usbkey`) + `bbox` (before `ownks`); the Link Cue task becomes `touchaudiot` |
| `--no-keyshift` | without `keyshift ks3k ownks`; `stock` layout, tadec at 0x08140000 |

Every MAIN entry point below that can run at boot tests `*0x0A35DF3C == 1` (normal boot) first.

## UI: GUI renderer and its MAIN helpers

### `v2ui` (GUI) and `v2needle` (MAIN) -- `mods/v2ui/`
- **Purpose:** our own CDJ-3000-style renderer: player, browse family, INFO, UTILITY, SHORT CUT, player INFO,
  pop-ups, waveforms (hardware band on GR2), Day Mode (LIGHT MODE), KEY FORMAT, six zooms, slip ghost, cue colours
  and comments, the master's waveform in the phase meter, the KEY SHIFT panel.
- **Entry:** `v2_paint(plane, base)` from `entry.S`, chained in front of the stock VDC base write 0x0E526626 (literals
  0x0E50923C and 0x0E508D1C). A few more stock call literals are chained through our table (`v2ui.py`).
- **Files:** `v2.c` / `v2.h` (renderer), `hwband.inc` (GR2 band), `hws2.inc`, `usblog.inc` (DEV HUD),
  `touch_map.py` + `touch_vt_zones.inc` (touch zones shared with MAIN), `fontgen.py`, `v2.ld`, `build.sh`,
  `check_sh2a.py`, `v2ui.py` (placement). Icons: `mods/v2ui_assets/`.
- **v2needle:** MAIN pokes that move the stock touch zones (SHORT CUT zones 53..69, strip, pads, header tiles) to the
  3000 layout. Applied by `v2ui.py`.

### `modsmenu` (MAIN) -- `mods/modsmenu/modsmenu.s`
- **Purpose:** our UTILITY items (LIGHT MODE, BPM DECIMALS, WAVEFORM COLOR, WAVEFORM CURRENT POSITION, WAVEFORM,
  KEY FORMAT, KEY SHIFT, KEY SYNC BUTTON, BUILD, the kill switches, and the hidden MODS / LINK CUE / WAV 32-BIT words),
  their saving, the publish words in the heartbeat, the 3000 touch layer (tap targets, drag, momentum, letter jump),
  the six-zoom knob hook, the build record and the kill words.
- **Entry (literal redirects):** touch_event 0x0844E240 / 0x0844E488 -> `v3e_touch`; knob poll 0x0844F1C8 ->
  `vt_khook`; settings unpack / pack 0x0846D990 / 0x0846D5D0 -> `mods_load` / `mods_save`; HISTORY-record memset
  0x0846D5D4 -> `hist_save`; heartbeat copies 0x08390944 / 0x08391B60 -> `mm_copy`. The UTILITY table pointer
  (4 literals) points at our table.
- **Placement:** FIXED at the layout's menu address; `patch_main.place_modsmenu()` copies the stock items, adds
  ours, orders them by `UT_ORDER`, and hides `UT_HIDE`.

### `font3000` (GUI) -- `mods/font3000/font3000.py`
Replaces the stock GUI's Latin font with the UI font (22.5 px) from `fonts/`. Container-level pseudo-mod.

### `ui3000x` (GUI) -- `mods/ui3000x/gui_ui3000x.s`
Recolours the stock chrome art in SDRAM once, before the first frame (title bars, row stripes, cursors), for the
parts stock still draws.

### `bootname` (GUI) -- `mods/bootname/gui_bootname.s`
Adds one text line under "Ver" on the boot screen (a ninth widget in the boot screen's widget list).

### `lang2` (GUI + MAIN) -- `mods/lang8.py`
English and Spanish only. GUI: 16 languages dropped (about 332 KB), tables fall back to English. MAIN: the
LANGUAGE item gets 2 options (block at 0x08017C00).

### `guitrim_cjk` (GUI) -- `mods/guitrim/`
GUI room: re-encodes the font archive with an optimal parse and zeroes the Chinese and Korean glyph banks. Applied
last. (`guitrim.py`, `lzsplice.py`.)

### `reclaim` (MAIN) -- `mods/reclaim/reclaim.py`
MAIN room (about 96 KB packed): every language uses the cp1252 path, the non-Latin code-page tables
(0x08101B00-0x08118700) are erased and their converters (0x084F151C-0x084F29D0) stubbed. Every byte is compared with
stock first.

### `usbkey` (MAIN) -- `mods/usbkey/main_usbkey.s`
The USB source key stays lit while the own USB is mounted. Entry: the lamp-pass literal 0x084DCBE8.

## Browse and waveforms

### `rowwave` (MAIN + GUI) -- `mods/rowwave/`
Browse rows in 3000 style: artwork thumbnail, mini waveform, and file type / BPM / key / duration. MAIN
`main_rowwave.s` / `main_rowwaveb.s` hook after the list parser (two call sites); GUI `gui_rowmeta.s`. Data at
RAMB + 0x10000.

### `three_band` (MAIN + GUI) -- `mods/three_band/`
3-band waveform data (PWV7 detail, PWV6 overview from the `.2EX`). MAIN: `main_wave3data.s` (hook right after the
detail builder's PWV5 fetch), `main_wave3detail.s`, `main_wave3ovfetch.s`, `main_wave3ovdata.s` (`main_wave3ovrgb.s`
recolours the stock overview of tracks without 3-band data). GUI: `gui_wave3*.s`. The v2ui renderer draws the
3000 colours from this data.

### `w8send`, `w8cap` (MAIN), `w8recv` (GUI) -- `mods/w8fetch/`
Message 0x31: the tempo master's PWV5 waveform and beat grid (for the phase meter WAVEFORM view), the loaded track's
cue block and artwork. `w8send` replaces the frame packer's last sub-packer call (0x0838EC76..0x0838EC86) and
streams through the stock chunk sender 0x083913C2 within the frame budget. It requests the master's data from the
stock DB task (mailbox 0x09435CC8, code 0x433, reply mailbox 0x5738). `w8cap` (0x0827C2CA..0x0827C2D8 in the DB
reply sender) keeps replies addressed to 0x5738. `w8recv` stores the chunks in GUI SDRAM 0x0CA00000+. State:
RAMB + 0x1E000 (`w8.inc`). Kill switches: MASTER WAVE NFS, MASTER WAVEFORM.

## Link Cue, audio, artwork

### `touchaudio`, `touchaudioip`, `touchaudiotouch` -- `mods/touch_audio/`
- **Purpose:** Link Cue / Touch Preview to a DJM-A9. The deck announces itself to the mixer as a device that streams
  preview audio, answers each mixer timing packet (UDP 50004, about every 7 ms) with one 336-frame audio packet, and
  plays the row or strip under the finger on the mixer's LINK CUE. Also: the loaded track's cue colours and comments
  (PCO2 from the `.EXT`) and artwork (through the stock JPU path, software fallback in tadec).
- **Entry:** `touchaudio` creates the task `TchAud` (priority 9) once, from the DJCONT_PASS hook, on a normal boot only.
  `touchaudioip` hooks the LINK receive path to learn the mixer address (UDP 50000). `touchaudiotouch` stops needle
  search on the strip while a preview plays. The JpegMgrTask free-path literal 0x083D6CF8 -> `jm_shim` serialises our
  artwork decodes with stock ones.
- **Files:** `main_touchaudio.s`, `main_touchaudioip.s`, `main_touchaudiotouch.s`, `main_touchaudiopack.s`,
  `README.md`. DEV variant: `dev/mods/touch_audio/main_touchaudiot.s`.
- Kill switches: LINK CUE, LINK ROW PREVIEW. Rule: never close the deck's own `export.pdb` from the task (the DB layer
  shares it).

### `tadec` (MAIN, FIXED) -- `mods/tadec/`
Decoder blob for the task: MP3 (`dr_mp3.h`), FLAC (`dr_flac.h`), JPEG (`stb_image.h`), our `tadec.c`, `crt.S`,
`tadec.ld`. Built by `build.sh` at the layout address with a 256 KB arena. Entry table: open, seek, read, rate, close,
jpeg (`mods/layout.inc`). *Unverified:* AIFF handling is described differently in older notes; check `tadec.c`.

### `wav32` (MAIN) -- `mods/wav32/`
Plays 32-bit WAV (int, float, extensible) by presenting it as 24-bit PCM and packing samples on read. Six signature
sites: `wav32fmt`, `wav32data`, `wav32fo`, `wav32seek`, `wav32rd`, `wav32rdend`.

## KEY SHIFT and KEY SYNC

### `keyshift` (MAIN, FIXED at KSB 0x08123000) -- `mods/keyshift/main_keyshift.s`
- **Purpose:** the KEY SHIFT front end (UTILITY KEY SHIFT, the panel -1 / RESET / +1 / K.SYNC), KEY SYNC, the KEY SYNC
  BUTTON on pad D/H, and the 3000 key fields in our status packet (`kx_send`).
- **Entry:** DJcont literal 0x082D8970 -> `ks_dj` (boot gate, then the engine); MASTER TEMPO setter literals
  0x0844DAC8 / 0x0844E1EC -> `mt_set`; hot-cue setter literals 0x0844D7AC / 0x0844DEF8 -> `hc_set`; pad-RGB getter
  0x0844FF7C -> `hc_lamp`; status send (builder 0x084B8132, UDP send 0x085117CA) wrapped by `kx_send`. `ksy_tick` runs
  every 128 ms and reads the GUI's KEY SYNC word.
- **Placement:** `mods/keyshift/keyshift.py` selects the `ks` layout and applies the engine named with it (`ownks`).
- Kill switches: KEY SYNC, LINK KEY STATUS.

### `ks3k` (MAIN) -- `mods/keyshift/main_ks3k.s`
Keeps a CDJ-3000 master's key from its 3000-format status packet (status receive hook at 0x083FE8E8, call site
0x083FE92A) at RAMB + 0x1E800 + player * 8. Adds the master's KEY SHIFT when its shift-valid flag is set.

### `ownks` (MAIN + DSP) -- `mods/ownks/`
Our Key Shift engine: `ownks.py` (boot-table rebuild, loader constants, checks for `verify_update`),
`main_ownks.s` (`oks_dj` at 0x08122000, state 0x08122800), `dsp/ownks.c` + `dsp/ks_tab.c` + `dsp/ownks.ld` (the C66x
pitch shifter at DSP 0x805C0000), `dsp/build.sh`, `dsp/build_toolchain.sh`. See `docs/dev/ARCHITECTURE.md` §5.
Requires `keyshift`; `patch_main.py` refuses `ownks` without it.

## Players 5 and 6 -- `mods/player56/`
- **Purpose:** the NXS2 can be player 5 or 6 (option A) and sees peers 5 and 6 (option B). UTILITY PLAYER No. offers
  AUTO, 1..6.
- **Patches (`--p56=proven`):** a1 own number range (0x083DFDAC), a2 status builder (0x084B8156), b1 status receive
  (0x083FE91E), b2 LNKH slot query (0x083FD212); the sync-module and master-detection switches go to the cave
  (`p56_stubA`, `p56_stubB`). Every patch checks the stock bytes first; the cave's allocation is gated on the boot word.
- **Files:** `player56.py`, `build_upd.py` (wraps `patch_update.py`), `build.sh`, `gen56.py` / `genui.py` (generate the
  call-site tables from *your* stock MAIN), `p56.c`, `p56ui.c`, `p56stub.S`, `p56ann.S`, `src78.S`, `p56.ld`,
  `sites.txt`, `sites_sess.txt`.
- Known limit: a stock NXS2 does not serve media to players 5/6.

## DEV only (`dev/mods/`)

### `autotest` (MAIN) -- `dev/mods/autotest/main_autotest.s`
Autotest runner: panel-decoder literals 0x0844D730 / 0x0844E23C, plus the `C:/V3TEST/SCRIPT.BIN` loader and the
commander's op queue, run from the TchAud loop. RELEASE keeps both literals stock.

### `usblog` (MAIN) -- `dev/mods/usblog/main_usblog.s`
RED log (UDP 50099), USB log (`C:/V3HUD.BIN`), network commander (UDP 50098, polled every 250 ms by TchAud). `hg_hook`
on the gui_comm RX-slot memset literal 0x0838EAEC takes each GUI HUD record before the slot is cleared.

### `bbox` (MAIN) -- `dev/mods/bbox/main_bbox.s`
BLACK BOX: no hook, no task. The TchAud loop calls its entry (`t_bbx`) once per pass; one 8,832-byte malloc inside the
boot gate. Samples watched values every 20 ms / 250 ms / 1 s, keeps the last 512 events (16 B each), dumps to
`C:/BLACKBOX.BIN` (256-byte `BBX1` header with the build ID and a state snapshot, then the events). Manual dump:
MENU + BACK 3 s. Automatic dumps on errors (at most 1 per 5 min, 8 per boot), only when safe (stick mounted >= 4 s,
nothing playing or loading). Kill switch: BLACK BOX.

### `touchaudiot` (MAIN) -- `dev/mods/touch_audio/main_touchaudiot.s`
The Link Cue task with test hooks: its loop also runs the autotest, usblog and bbox ticks. The patcher takes it
instead of `touchaudio` when `autotest` or `usblog` is named.

## Kill switches

UTILITY > INFO, after BUILD / VERSION No. 1 = feature, 0 = the stock path at the feature's entry. Live, not saved (ON
at every boot). RELEASE shows them always after boot; DEV while TEST LOG is not OFF.

| row | word | OFF means |
|---|---|---|
| LINK KEY STATUS | KSB + 100 | status goes out as stock 0x124 B |
| KEY SYNC | KILLB + 0 | no new KEY SYNC; pad D/H stock |
| LINK CUE | modsmenu LINK CUE word | no Link Cue / Touch Preview |
| MASTER WAVE NFS | KILLB + 4 | w8send does not try the NFS route |
| MASTER WAVEFORM | KILLB + 8 | phase meter WAVEFORM shows the grid only |
| HW BAND LAYER | KILLB + 12 | software band instead of GR2 |
| LINK ROW PREVIEW | KILLB + 16 | no row preview on a LINKed medium |
| BLACK BOX | KILLB + 20 | recorder stops (DEV only) |

KILLB = 0x080141E0 in the `ks` layout.

## Not in either recipe

`mods/mods.conf` and the patcher tables still know other mods (for example OSC, TCNet, Ableton Link, USB-MIDI,
phrase colours, jog probes). Their sources are not part of this repository, and `patch_main.py` / `patch_gui.py` drop
table entries whose source is missing.

# usblog — the TEST builds' log (stick file or LINK broadcast) and network commander

MAIN side: `main_usblog.s` (run from the TchAud task, normal boot only). GUI side: `../v2ui/usblog.inc`.
Design: `re/USB_LOG_DESIGN.md`, `re/AUTOTEST_USBLOG.md`; commander: `re/AUTOTEST_DESIGN.md` §7.
Tools: `tools/commander/{netlog.py,decode_usblog.py,cmd.py}`.

## Build identity (V4n36 trace)

Every build made by `work/v4n/build_final.sh` carries a **build ID**:

    TAG YYYYMMDD-HHMM HASH8        e.g.  V4n36t1 20261114-1240 3f0c9a12

`HASH8` = the first 8 hex digits of sha256 over every source under `mods/` (path + content, sorted; `.s .S .c .h
.inc .py .ld .sh .conf`, no caches / blobs): `patch_main.source_hash()`. The ID is exported as `CDJ_BUILD_ID`
before the build (so `verify_update.py` rebuilds the same bytes) and, once the UPD is written, one line goes to
`BUILDS.tsv`: `build ID <TAB> tag <TAB> UPD sha256 <TAB> written <TAB> path`.

Where it is visible:

| where | what |
|---|---|
| UTILITY > BUILD (INFO, read-only, before VERSION No.) | `TAG HASH8` |
| MAIN RAM, **fixed address `BLDID` = 0x08014180** (ks layout: modsmenu block 0x08014000 + 0x180; layout.inc) | 48 bytes: `"BLD1"` + the ASCII ID, NUL-padded; then 48 bytes UTF-16LE `TAG HASH8` (the UTILITY value) |
| network commander | `cmd.py ver` (a MEM read of `BLDID`, 48 bytes) prints the ID and its UPD sha from BUILDS.tsv |
| RED / USB log | the `'V3HB'` boot record (format 2): w8..w19 = the 48-byte build record, w20 TEST LOG (1 USB, 2 RED); RED sends it once per boot (first network flush). `decode_usblog.py` prints `BUILD <id>` |

A build without the record (before V4n36 trace) answers `ver` with no `BLD1` magic.

## Kill switches (V4n36 trace)

Fixed address **`KILLB` = 0x080141E0** (modsmenu block + 0x1E0): words, 1 = ON (the feature), 0 = OFF (its stock
path, checked at the feature's entry). Live, not saved (ON at every boot). UTILITY rows after VERSION No., shown
only while TEST LOG is not OFF (modsmenu `kl_reveal` sets the item count); also pokeable over the commander.

| item | word | OFF = |
|---|---|---|
| LINK KEY STATUS | KSB+100 = 0x08123064 (keyshift `kx_on`) | stock 0x124-byte status packet |
| KEY SYNC | KILLB+0 | no new KEY SYNC (tile / pad; a running one ends), KEY SYNC BUTTON pads + lamps stock |
| LINK CUE | modsmenu `lc_off` 0x080140F4 (OFF / PREVIEW / CUE / BOTH) | no Link Cue streaming |
| MASTER WAVE NFS | KILLB+4 | w8send never starts the NFS lookup (`nfs:` -> `none`) |
| MASTER WAVEFORM | KILLB+8 (display) | phase meter WAVEFORM view = the master's beat grid only |
| HW BAND LAYER | KILLB+12 (display) | `hb_frame` returns 0: the software band |
| LINK ROW PREVIEW | KILLB+16 | no row touch on a LINKed medium's list (as LINK CUE without PREVIEW) |

The display's two reach the GUI in heartbeat +0x18 (`0x4B << 24 | bit 0 MASTER WAVEFORM | bit 1 HW BAND`, modsmenu
`sl_pub`) whenever SLIP does not use the word; the GUI keeps the last one seen (`g_kill`, v2.c).

## HUD records over RED (#51, V4n36 trace)

MAIN's `gui_comm` memsets each RX slot (0x4000 B, 0xA9072B38 + slot << 14) right after parsing it, so the 250-ms
poll (`gui_take` / `rx_pick`) only saw the GUI's HUD block (+0x800) when it happened to look before the clear: on
the deck whole boots had none (decks' net logs 2026-11-14: V3US w11 RX magic 0 for the whole session; other boots
fine — both loops periodic, so it is all-or-nothing per boot). Fix: `hg_hook` (usblog + 16) takes the memset
literal 0x0838EAEC (patch_main `place_hudgrab`): on a normal boot, before an RX slot is cleared, a consistent HUD
block with a newer head has its newest record copied to `hg_rec`; `hg_take` adds it to the ring (the per-second GUI
record: fps, cpu_load w28, screen w29). V3US w28 = the head last caught, w29 = records caught.

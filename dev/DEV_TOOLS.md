# DEV tools -- using the DEV build (`R23U1n`) on a test rig

Everything here needs the **DEV** profile (`PROFILE=dev ./build.sh ...`, UTILITY > BUILD `R23U1n 49e8943c`).
The RELEASE build (`R23U1r`) has none of the deck-side hooks: it does not listen on UDP 50098, sends nothing on
50099, has no autotest runner and no HUD. Only the BLACK BOX stick dump (MENU + BACK 3 s) and the kill switches
exist in both.

The PC side is plain Python 3 (standard library; `rig.py` needs PyYAML only for `.yaml` plans), in `tools/`:

| path | what |
|---|---|
| `dev/tools/commander/cmd.py` | network commander: send panel ops, read MAIN RAM, read the build ID, listen to records |
| `dev/tools/commander/atc.py` | autotest script compiler (the op syntax `cmd.py send` and `SCRIPT.BIN` share) |
| `dev/tools/commander/netlog.py` | RED log listener: writes the deck's UDP 50099 records to `V3HUD_<date>.BIN` |
| `dev/tools/commander/decode_usblog.py` | HUD / status log decoder (stick `V3HUD.BIN` or a netlog file): fps, CPU, screen |
| `dev/tools/bbox/decode_bbox.py` | BLACK BOX decoder (`BLACKBOX.BIN` from the stick, or the `V3BB` records of a netlog file) |
| `dev/tools/bbox/bblisten.py` | BLACK BOX / RED records from an emulator's multicast segment |
| `dev/tools/rig/rig.py` + `prodjlink.py` | declarative test plans over Pro DJ Link: our decks via the commander, stock decks / mixer via DJ Link |
| `dev/tools/rig/stagehand.py` | reads DJM-A9 faders / EQ / VU as the Stagehand iPad app does (port of alphatheta-connect, MIT) |
| `dev/tools/rig/plans/*.py` | `solo3`, `net4_dd`, `ksync_rig2`, `ksync_mtap`, `lc_linkcue` |
| `dev/tools/rig/tools/` | `lc_pcap.py` (Link Cue on the wire from pcaps), `pcapsum.py` (per-packet-type summary) |
| `dev/tools/testreport.sh` | one text report per build: sha, sizes, gates, latest rig runs |

## 1. Network setup
- The PC is on the Pro DJ Link segment (switch or the mixer's LINK ports), on the link-local net
  169.254.0.0/16 like the decks, e.g. `sudo ifconfig en4 alias 169.254.77.10 netmask 255.255.0.0` (macOS) or
  `ip addr add 169.254.77.10/16 dev eth1` (Linux). Our tools broadcast to 169.254.255.255 by default.
- On each DEV deck: UTILITY > TEST LOG = **RED** (the default on DEV; not saved, RED again at each boot). OFF stops
  the commander and the log; USB writes the log to the stick instead (`C:/V3HUD.BIN`; can stutter the waveform).

## 2. Network commander (`cmd.py`, deck UDP 50098 -> answers on 50099)
```
python3 dev/tools/commander/cmd.py ver                                  # BUILD R23U1n 20261124-1811 49e8943c (+ UPD sha if BUILDS.tsv knows it)
python3 dev/tools/commander/cmd.py --ip 169.254.128.46 send "KEY INFO" "WAIT 2000" "TOUCH 28 235"
python3 dev/tools/commander/cmd.py --done send "KEY PLAY" "WAIT 5000" "KEY PLAY"     # wait until the ops ran
python3 dev/tools/commander/cmd.py mem 0x08014180 48                    # MAIN RAM read, 1..64 bytes (the build record)
python3 dev/tools/commander/cmd.py mem 0x080141E0 24                    # the kill-switch words (1 = feature ON)
python3 dev/tools/commander/cmd.py listen                               # print every record the decks send
```
- Datagram `ATC1` + seq + ops in the 8-byte SCRIPT.BIN encoding (`atc.py`); up to 60 ops. The deck appends them
  to its autotest runner and answers `V3CK` (taken / status), `V3CD` (done) and `V3MM` (memory) on 50099.
- Op syntax (see `atc.py` docstring): `KEY name [ms]`, `ROT n`, `TOUCH x y [ms]` (800x480), `WAIT ms`, `MARK id`,
  `LOOP n ... END`. Real panel input during a script is logged, not an abort reason.
- `mem` reads only DRAM (0x08000000..0x18000000 and its mirrors). `--mcast G:P` talks to an emulator segment.
- `ver` looks the build ID up in a `BUILDS.tsv` (`CDJ_BUILDS=path`, columns: build ID, tag, UPD sha256, date,
  path) if you keep one.

## 3. RED log, HUD, CPU / fps (`netlog.py` + `decode_usblog.py`)
```
python3 dev/tools/commander/netlog.py 50099 ~/v3logs/net                # run during the whole session
python3 dev/tools/commander/decode_usblog.py ~/v3logs/net/V3HUD_<date>.BIN                 # summary of the last boot
python3 dev/tools/commander/decode_usblog.py V3HUD_<date>.BIN --session all --csv hud.csv   # every boot, per second
```
- One 128-byte record per datagram, the same format as the stick file: a `V3HB` boot record (MAIN version, build
  record, TEST LOG mode), one GUI HUD record a second (F frames painted, G worst gap ms, D draw ms, band / copy
  ms, latch waits, rebuilds; w28 = **GUI CPU %**, w29 = screen | model), one `V3US` MAIN status a second (stick
  state, RX slot, artwork / cue / title chain), `V3MK` marks, `V3AE` autotest end, `V3BB` BLACK BOX events.
- The decoder prints per autotest step (or per minute without a script): seconds, fps mean / min, worst gap,
  draw ms, CPU %. `--marks SCRIPT.marks` names the steps.
- The HUD counters are computed by the DEV GUI (`-DV2_HUD`) once a second and travel to MAIN in the SPI frames;
  MAIN (usblog) takes each record before it clears the RX slot, so none are lost.

## 4. Autotest scripts from the stick (`atc.py`)
```
python3 dev/tools/commander/atc.py build mytest.txt SCRIPT.BIN          # + SCRIPT.marks for decode_usblog
python3 dev/tools/commander/atc.py full 3 v4_full.txt                   # the default full test, tracks 1..3
python3 dev/tools/commander/atc.py dump SCRIPT.BIN
```
Copy `SCRIPT.BIN` to `C:/V3TEST/SCRIPT.BIN` (and an empty `C:/V3HUD.BIN` for TEST LOG = USB) and boot: the
script runs once the stick is mounted. `atc.py emu` drives our emulator (not shipped; ignore it).

## 5. BLACK BOX (both profiles)
- Dump: deck **stopped**, hold **MENU + BACK 3 s** -> one dump appended to `C:/BLACKBOX.BIN` (256-byte `BBX1` header
  with the build ID and a state snapshot, then up to 512 16-byte events, oldest first). Automatic dumps on errors
  (Link Cue send / open failures, a load that fails or takes >= 20 s): max 1 per 5 min, 8 per boot. Only while
  the stick has been mounted >= 4 s, nothing playing / loading / previewing.
- Decode: `python3 dev/tools/bbox/decode_bbox.py BLACKBOX.BIN [--last] [--raw]` (also takes a netlog file: DEV streams
  the same events live as `V3BB` records).
- Off: UTILITY > INFO > BLACK BOX = OFF (kill switch, until the next boot).

## 6. Rig plans (`rig.py`)
```
cd dev/tools/rig
python3 rig.py plans/solo3.py      --lan 169.254.77.10 --keep-going --out runs/v38_solo3   # one deck: 5 formats load + play
python3 rig.py plans/net4_dd.py    --lan 169.254.77.10 --keep-going --out runs/v38_net4    # 2 of our decks: LINK loads, SYNC both ways, master
python3 rig.py plans/ksync_rig2.py --lan 169.254.77.10 --keep-going --out runs/v38_ks_ab   # KEY SYNC: master 3 -> sync 2
python3 rig.py plans/ksync_rig2.py --lan 169.254.77.10 --keep-going --set m=2 --set s=3 --out runs/v38_ks_ba
python3 rig.py plans/ksync_mtap.py --lan 169.254.77.10 --keep-going --out runs/v38_mtap    # K.SYNC tapped on the master = refused
```
- `--lan` = the PC's own DJ Link address. Player numbers, track rbids and deck IPs are plan `vars`: override with
  `--set A=2 --set B=3`. The plans expect the rekordbox stick layout described in each plan's header (e.g. TRACK
  list 1 MP3, 2 FLAC, 3 WAV, 4 AIFF, 5 WAV).
- Output: `runs/<name>/rig.jsonl` (every event) + `report.txt` (PASS / FAIL / SOFT / SKIP per step); exit 1 on a hard
  failure. `--keep-going` runs every step anyway.

### Link Cue plan with the fake DJM-A9 (`lc_linkcue`)
> **WARNING: the fake A9 only on an isolated segment WITHOUT a real mixer.** A second DJM-A9 identity on a network
> with a real one hangs the real mixer. `rig.py` refuses the fake A9 when a mixer is already seen, and on a real
> network only with the plan's `allow_fake_a9_lan: true` (or `--allow-fake-a9-lan`).
```
sudo ifconfig en4 alias 169.254.142.194 netmask 255.255.0.0                 # the fake A9's own address
python3 rig.py plans/lc_linkcue.py --lan 169.254.77.10 --keep-going --out runs/v38_lc      # local + remote preview
sudo ifconfig en4 -alias 169.254.142.194
python3 tools/lc_pcap.py 169.254.142.194 T0 T1 caps/*.pcap                  # optional wire cross-check
```
Holds a browse row 22 s on deck A (own USB) and on deck B (A's USB over LINK) for MP3 / FLAC / WAV (AIFF must stay
silent) and checks the fake A9 receives non-silent PCM at ~142.9 packets/s and that it stops after release.
Set `ipA` / `ipB` (the decks' addresses) with `--set`.

## 7. Test report (`testreport.sh`)
```
BUILDS=BUILDS.tsv dev/tools/testreport.sh R23U1n out-dev dev/tools/rig/runs   # -> out-dev/TESTREPORT_R23U1n.txt
```
Build sha + sizes (from `build.log`), the gates (`verify.txt`, `bootcheck.txt`) and the latest rig run of each plan
(a run named with this build's prefix `v38_` / `r2_` preferred).

## 8. Addresses the tools use (MAIN, `ks` layout)
| address | what |
|---|---|
| 0x08014180 | build record: `BLD1` + ASCII build ID (44 B), then the UTILITY BUILD text in UTF-16 (48 B) |
| 0x080141E0 | kill words, 1 = ON: +0 KEY SYNC, +4 MASTER WAVE NFS, +8 MASTER WAVEFORM, +12 HW BAND LAYER, +16 LINK ROW PREVIEW, +20 BLACK BOX |
| 0x08123000 (KSB) | Key Shift / KEY SYNC front end: +4 panel, +48 KEY SYNC on, +64 refusal tick, +100 LINK KEY STATUS |
| 0x080140F0 | MODS / LINK CUE / WAV 32-BIT words |
| 0x081FFE80 | Link Cue (TchAud) counters |

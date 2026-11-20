# dev/ -- the DEV build and the developer tools

This folder is for contributors. Players do not need it: the normal build (`./build.sh C2KNXS2.UPD`) is the
RELEASE build and uses nothing from here.

> **The RELEASE build has none of this.** No black box, no logs, no network commander, no autotest, no HUD and no
> TEST LOG item. It does not listen on UDP 50098 and sends nothing on UDP 50099.

## What is here

| path | what |
|---|---|
| `dev/mods/autotest/` | MAIN: autotest runner. Plays a panel script (`C:/V3TEST/SCRIPT.BIN` or ops from the commander) |
| `dev/mods/usblog/` | MAIN: the RED network log (UDP 50099), the USB log `C:/V3HUD.BIN`, the network commander (UDP 50098) |
| `dev/mods/bbox/` | MAIN: the BLACK BOX event recorder (dump to `C:/BLACKBOX.BIN` on MENU + BACK 3 s) |
| `dev/mods/touch_audio/main_touchaudiot.s` | the test variant of the Link Cue task (`TchAud`): its loop also runs the autotest, log and black-box ticks |
| `dev/tools/commander/cmd.py` | network commander: send panel ops, read MAIN RAM, read the build ID, listen to records |
| `dev/tools/commander/atc.py` | autotest script compiler (`SCRIPT.BIN`; the same op syntax `cmd.py send` uses) |
| `dev/tools/commander/netlog.py` | RED log listener: writes the deck's UDP 50099 records to `V3HUD_<date>.BIN` |
| `dev/tools/commander/decode_usblog.py` | HUD / status log decoder (stick `V3HUD.BIN` or a netlog file): fps, CPU, screen |
| `dev/tools/bbox/decode_bbox.py` | BLACK BOX decoder (`BLACKBOX.BIN`, or the `V3BB` records of a netlog file) |
| `dev/tools/bbox/bblisten.py` | collects black-box / RED records from an emulator's multicast segment (for emulator users) |
| `dev/tools/rig/` | `rig.py` + `prodjlink.py`: declarative deck test plans over Pro DJ Link; `stagehand.py` (mixer read-out); `plans/`; `tools/` (pcap helpers) |
| `dev/tools/testreport.sh` | one text report per build: sha, sizes, gates, latest rig runs |
| `dev/DEV_TOOLS.md` | the full manual for all of the above |

The PC tools are plain Python 3 (standard library; `rig.py` needs PyYAML only for `.yaml` plans).

## Building DEV

You need your own official `C2KNXS2.UPD` 1.87, as for the RELEASE build.

```
PROFILE=dev ./build.sh /path/to/C2KNXS2.UPD          # -> out-dev/C2KNXS2.UPD  (= V4n21)
```

- `build.sh` copies the repository's `mods/` and `scripts/` into a work copy, then copies `dev/mods/` over it.
  The source tree is never changed.
- DEV uses the same features as RELEASE, plus `autotest`, `usblog` and `bbox` in the MAIN mod list, and the GUI
  flags `-DV2_HUD -DV2_USBLOG`. When `autotest` or `usblog` is named, the patcher takes the test variant of the
  Link Cue task (`touchaudiot`) instead of the normal one.
- The same gates run (`verify.txt`, `bootcheck.txt`). Do not install a DEV build that failed them.
- The DEV labels are set by the build like RELEASE (see `CONTRIBUTING.md`, "Labels and version bump").
- UTILITY > INFO > BUILD shows the DEV build ID.

## What DEV adds on the deck

| feature | how |
|---|---|
| **UTILITY > INFO > TEST LOG** | OFF / USB / RED. Default RED, not saved (RED again at every boot). OFF stops the commander and the logs. |
| **RED log** | UDP 50099 broadcast, one 128-byte record per datagram: boot record, a GUI HUD record and a MAIN status record each second, marks, black-box events. |
| **USB log** | TEST LOG = USB writes the same records to `C:/V3HUD.BIN` (create the empty file first). Can stutter the waveform. |
| **Network commander** | UDP 50098: panel ops (keys, knob, touch, waits), MAIN RAM reads (1..64 bytes), build ID. Answers on 50099. |
| **Autotest** | `C:/V3TEST/SCRIPT.BIN` (compiled with `atc.py`) runs once the stick is mounted. Real panel input during a script is logged, not an abort. |
| **HUD** | the GUI measures frames, worst gap, draw time and **GUI CPU %** each second and sends it to MAIN in the SPI frame. |
| **BLACK BOX** | a RAM ring of the last 512 deck events; MENU + BACK 3 s (deck stopped) appends a dump to `C:/BLACKBOX.BIN`; automatic dumps on some errors; also streamed live as `V3BB` records on the RED log. |
| **Kill-switch rows** | shown at the end of UTILITY > INFO while TEST LOG is not OFF (1 = feature on, 0 = stock path; not saved). |

Everything above is gated on a normal boot, like every other mod: in update mode none of it runs.

## Quick start

```
python3 dev/tools/commander/netlog.py 50099 ./logs                     # keep running during the session
python3 dev/tools/commander/cmd.py ver                                 # which build is on the deck
python3 dev/tools/commander/cmd.py --done send "KEY PLAY" "WAIT 5000" "KEY PLAY"
python3 dev/tools/commander/decode_usblog.py ./logs/V3HUD_<date>.BIN   # fps / CPU summary of the last boot
python3 dev/tools/bbox/decode_bbox.py BLACKBOX.BIN --last
```

The PC must be on the Pro DJ Link segment, on the link-local net 169.254.0.0/16 like the decks. Network setup,
the op syntax, the address table the tools use and every rig plan are in `dev/DEV_TOOLS.md`.

## Getting and installing DEV
- Build it from source: `PROFILE=dev ./build.sh /path/to/C2KNXS2.UPD` → `out-dev/C2KNXS2.UPD`. For this version the
  expected sha256 is `c8d39cbeb6ad78e26e23d6aa3b5c2c51c571124fefb0fed9098cbcdfc8012610` (reference toolchain, unchanged sources). **Cueline Builder cannot make DEV builds**
  (its patch data is the RELEASE build only).
- Install exactly like RELEASE (small FAT32 stick, only `C2KNXS2.UPD`, official update procedure; never power off).
- **DEV ↔ RELEASE:** both builds of a version carry the same label (MAIN 2.10 / GUI 2.04), so switching
  between them in either direction is skipped by the deck unless you do UTILITY → DUPLICATION → DEFAULT first (it
  resets the deck settings). Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION → DEFAULT.
  Going back to the official 1.87 works the same way (README → Going back to stock).

## Security and privacy
- The **network commander** (UDP 50098) accepts requests from **any computer on the LINK network**: it answers
  version and memory reads and **executes panel operations** (keys, touches, the jog knob) sent with
  `cmd.py send`. Use DEV only on your own network; set UTILITY → TEST LOG = **OFF** to stop the commander and the
  log when you don't need them (TEST LOG is RED again at every boot).
- The **RED log** is broadcast on the LINK subnet (UDP 50099): every computer on that network can receive it.
- **Logs and black-box dumps describe your media and setup** (track IDs, and in some records titles or file names;
  LINK members). Check the decoded output (`decode_bbox.py`, `decode_usblog.py`) before you attach it to a public
  issue.

## Reporting a bug with DEV data
1. UTILITY → INFO → **BUILD** id.
2. Right after the problem, deck stopped: **MENU + BACK 3 s** → `BLACKBOX.BIN` on the stick.
3. Network log (optional): TEST LOG = RED, a computer on the LINK network, then
   `python3 dev/tools/commander/netlog.py 50099 ~/cueline-logs` while you reproduce it →
   `~/cueline-logs/V3HUD_<date>.BIN`. Or TEST LOG = USB with an empty `V3HUD.BIN` in the stick's root.
4. Open an issue with the Bug report template; attach `BLACKBOX.BIN`, the log file, photos / video.

## WARNING: the fake DJM-A9 in the rig plans

The Link Cue plan (`dev/tools/rig/plans/lc_linkcue.py`) can act as a **fake DJM-A9** to receive the preview audio.

> **Use the fake A9 only on an isolated network segment WITHOUT a real mixer.** A second DJM-A9 identity on a
> network with a real one hangs the real mixer. `rig.py` refuses the fake A9 when it sees a mixer, and on a real
> network only runs it with the plan's `allow_fake_a9_lan: true` (or `--allow-fake-a9-lan`). Never use it at a gig
> or on someone else's network.

## Notes

- `cmd.py ver` reads the build record at the `ks`-layout address by default. For a build without Key Shift (the
  `stock` layout) pass `CDJ_BLDID=<address>`; the addresses are listed in `dev/DEV_TOOLS.md`.
- The emulator that maintainers use is not part of this repository. Options such as `atc.py emu` or
  `--mcast` exist for emulator users; ignore them on a real deck.

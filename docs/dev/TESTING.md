# Testing

How a change is tested, from the build gates to a real deck. The DEV tools are described in full in
`dev/DEV_TOOLS.md`; this page is the overview and the checklist.

## 1. Build gates (every build, automatic)

| gate | file | PASS looks like |
|---|---|---|
| `scripts/firmware/verify_update.py` | `out-<profile>/verify.txt` | last line `verify_update: all checks passed` |
| `scripts/firmware/gui_bootcheck.py --strict` | `out-<profile>/bootcheck.txt` | first line starts with `PASS` |
| reference sha | `build.sh` output | `== <TAG> reference build, byte-identical` (only for unchanged sources) |

Also read `build.log` for:
- the GUI section size (must be at or below stock: 6,931,940 B);
- `MAIN packs to N of M bytes`: the packed MAIN must fit;
- `patch_main: modsmenu: ... not installed` or `... left stock`: a literal did not hold its stock value, so a hook
  was skipped;
- the UTILITY item list printed by `place_modsmenu`.

Never install a build that failed a gate.

## 2. The racegate (maintainers)

The update path is the riskiest moment for a deck, so every candidate is run through it twice in an emulator before
a deck sees it:

1. Make a variant of the build whose Link Cue task would spawn very early (the worst order).
2. Install it, then run update mode with a small rescue update and with the official 1.87.
3. PASS: no CPU reset, the task never started in update mode, and the updater reaches its normal file states.

The emulator and the racegate script are not part of this repository. If your change touches boot, the heartbeat,
tasks, `malloc`, or any hook that can run before the stick is mounted, ask for a racegate run in your pull request.

## 3. On a real deck

### Install
- Install **from stock** (official 1.87) with a **small, fast FAT32 stick** that holds only `C2KNXS2.UPD`.
- Use a UPS if you can. Never touch the deck or the stick during the update.
- Check UTILITY > INFO > BUILD after the reboot.
- A build with the same label as the installed one is skipped: do UTILITY > DUPLICATION > DEFAULT first, or go back
  to stock first.

### Smoke test (any change)
1. Boot to the player screen; no error code.
2. Load from USB and SD (rekordbox export): MP3, FLAC, WAV, AIFF. Play, CUE, a loop, a hot cue.
3. Browse: scroll, drag, load from a row. INFO, UTILITY, SHORT CUT open and close cleanly.
4. If the change is visual: compare with the screens before your change, in both LIGHT MODE settings you touched.
5. An update **from** your build back to stock (DEFAULT, then the official 1.87). This proves update mode still works
   with your code installed.

### Rig plans (DEV build, Pro DJ Link)
`dev/tools/rig/rig.py` runs declarative plans against our decks (through the network commander) and stock decks /
the mixer (through Pro DJ Link):

| plan | what it checks |
|---|---|
| `plans/solo3.py` | one deck: the formats load and play |
| `plans/net4_dd.py` | two of our decks: LINK loads, SYNC both ways, master hand-over |
| `plans/ksync_rig2.py` | KEY SYNC: master deck -> synced deck (swap with `--set m=.. --set s=..`) |
| `plans/ksync_mtap.py` | K.SYNC tapped on the master is refused |
| `plans/lc_linkcue.py` | Link Cue local and remote preview, with a **fake DJM-A9** (isolated network only) |

```
cd dev/tools/rig
python3 rig.py plans/solo3.py --lan <PC link-local address> --keep-going --out runs/<name>
```
Output: `runs/<name>/rig.jsonl` (all events) and `report.txt` (PASS / FAIL / SOFT / SKIP per step). Each plan's
header lists the rekordbox stick layout it expects.

> **The fake DJM-A9 only on an isolated segment without a real mixer.** A second A9 identity next to a real one hangs
> the real mixer. See `dev/README.md`.

`dev/tools/testreport.sh <TAG> <out-dir> dev/tools/rig/runs` writes one text report per build (sha, sizes, gates,
latest rig runs). Paste its summary into your pull request.

## 4. DEV observability

All of this needs the DEV build (`PROFILE=dev ./build.sh ...`) and UTILITY > INFO > TEST LOG = RED (the default).

- **RED log:** `python3 dev/tools/commander/netlog.py 50099 ./logs` during the whole session, then
  `python3 dev/tools/commander/decode_usblog.py ./logs/V3HUD_<date>.BIN` for fps (mean / min), worst frame gap, draw
  time and **GUI CPU %** per autotest step or per minute. `--session all --csv hud.csv` for every boot, per second.
- **USB log:** TEST LOG = USB, with an empty `C:/V3HUD.BIN` on the stick. Same records, same decoder. It can stutter
  the waveform: prefer RED.
- **Commander:** `python3 dev/tools/commander/cmd.py ver | send ... | mem ADDR N | listen`. `send` takes panel ops
  (`KEY name [ms]`, `ROT n`, `TOUCH x y [ms]`, `WAIT ms`, `MARK id`, `LOOP n ... END`); `--done` waits until they ran.
  `mem` reads 1..64 bytes of MAIN DRAM (for example the build record or the kill words).
- **Autotest from the stick:** `python3 dev/tools/commander/atc.py build mytest.txt SCRIPT.BIN`, copy to
  `C:/V3TEST/SCRIPT.BIN`, boot. `atc.py full 3 out.txt` writes the default full test for tracks 1..3.
- **BLACK BOX:** deck stopped, hold MENU + BACK 3 s -> `C:/BLACKBOX.BIN`. Decode with
  `python3 dev/tools/bbox/decode_bbox.py BLACKBOX.BIN [--last] [--raw]` (it also reads the `V3BB` records of a RED
  log). Events cover play mode, the loaded track and load results, SYNC / MASTER, tempo master, KEY SYNC and its
  refusal reason, KEY SHIFT, Link Cue counters, LINK join / leave, and dump results.

## 5. Debugging tips and lessons learned

- **Start from the evidence on the deck.** The emulator never reproduced the panel latch tearing or the VDC4 scroll
  register behaviour; both were found on the real deck with a camera. For display and timing work, a phone video at
  high frame rate beats any log.
- **Physical checks first.** Before suspecting the firmware: try another (small, fast) stick, re-export from rekordbox
  to a clean stick (an old `PIONEER` folder once made menus disappear), check the LINK cables and switch, power the
  mixer and decks properly. An update that "will not install" was once a slow stick racing our task.
- **Install from stock with a small stick** whenever you test a build that changes boot or task code.
- **Use the kill switches** to bisect: if a problem goes away with one row OFF, the bug is behind that entry point.
- **The black box first, then the logs.** A dump right after the problem tells you the last 512 state changes and
  the build ID; the RED log tells you fps and CPU around it.
- **Stale blobs.** If a change seems to have no effect, run `python3 mods/patch_main.py --assemble` (and
  `patch_gui.py --assemble`); `build.sh` does this, a manual patch run may not.
- **A skipped hook is silent on the deck.** `place_modsmenu` and other placers print "not installed" when a literal
  does not hold its stock value. Read `build.log`.
- **Big-endian GUI, little-endian MAIN.** Data that crosses the SPI link as 32-bit words can arrive byte-reversed
  (message 0x31 payloads are reversed per 4 bytes and fixed by `w8recv`).
- **Read the models uncached in the GUI** (+0x20000000): they are filled by DMA.
- **Settings:** settings byte 6 bit 0 is stock's "invalid record" flag; storing a value there once wiped every
  setting. The HISTORY-name tail holds several of our settings and only works with a HISTORY name of 29 bytes or less.
- **GUI room is tight.** Measure the GUI section after every GUI change; trim before you add.
- **Never test a GUI timing change on a deck you need for update mode.** The installed GUI draws the update screen.

## 6. What to put in a pull request

- Build IDs and both gate lines for RELEASE and DEV.
- Deck(s), mixer, firmware of other players, stick type.
- The plans or steps you ran and their result (`report.txt` / `testreport.sh` output).
- What you could not test (for example: no CDJ-3000, no DJM-A9).

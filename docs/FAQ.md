# Cueline FAQ and troubleshooting

Cueline is unofficial firmware for the CDJ-2000NXS2. It is not affiliated with or endorsed by Pioneer DJ /
AlphaTheta. You use it at your own risk. Test it at home before any gig.

See also: `USER_GUIDE.md` (every feature) and `KNOWN_LIMITS.md` (what does not work yet).

---

## Installing

### What do I need?

- A CDJ-2000NXS2.
- The **official CDJ-2000NXS2 firmware 1.87** from the Pioneer DJ / AlphaTheta website. Unzip it to get
  `C2KNXS2.UPD`. Cueline is built from this file on your own computer. We never ship Pioneer files.
- A computer to build your Cueline update (see **Building** below).
- A **small, empty USB stick formatted FAT32**.

### How do I install it?

1. If you use MY SETTINGS, save them with rekordbox first.
2. Copy your built `C2KNXS2.UPD` **alone** to the root of the FAT32 stick. No other files.
3. Switch the deck off. Insert the stick.
4. Start the update exactly as Pioneer DJ's official CDJ-2000NXS2 update guide describes.
5. Wait until the update reaches 100 % and says it is complete. Then switch the deck off and on.
6. Check UTILITY > INFO > **BUILD**. It must show `Cueline-2.3 2cd1c93f`.

**Never switch the deck off, and never pull the stick, while the update runs.**

### Why a small, empty stick?

The update screen only needs the one file. A small, empty stick is ready quickly when the deck starts. Other files
on the stick, or a large stick that is slow to mount, only add risk.

### Is it safe? What if the power goes off during the update?

Bricking a CDJ-2000NXS2 is hard, but not impossible. The main risk is a **power cut while the update is being
written**.

- Use a **UPS** (an uninterruptible power supply) if you can.
- Do not touch the deck or the stick during the update.
- Keep the official 1.87 `C2KNXS2.UPD` at hand.
- If an update is interrupted, put the stick with the **official** `C2KNXS2.UPD` back in. The deck's own emergency
  updater starts from USB at the next power-on and recovers. Leave the stick in and let it finish.

In update mode, Cueline's own code does nothing. Every update, ours or the official one, is written by the deck's
stock updater.

### I installed an update but the deck still shows the old version. Why was it skipped?

The deck only installs an update whose version number is **newer** than the one it remembers as installed.

- Cueline uses a **higher** version number than the official firmware. So it installs directly over stock.
- The official 1.87 has a **lower** number than Cueline. So the deck **skips** it. Nothing is written.
- The same happens if you install an **older** Cueline build over a newer one.

The fix is a factory reset first: **UTILITY > DUPLICATION > DEFAULT** (disconnect the Pro DJ Link (LAN) cable
first: while LINK is active the player does not allow DUPLICATION > DEFAULT). It clears the remembered version. After that,
the lower version installs normally.

### How do I go back to the official firmware?

1. **Write down your deck settings**, or save MY SETTINGS with rekordbox. The factory reset erases them.
2. Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION > DEFAULT. Then, on the deck: **UTILITY > DUPLICATION > DEFAULT**. Confirm.
3. Put the **official, unchanged** 1.87 `C2KNXS2.UPD` **alone** on a FAT32 stick. Its sha256 must match the one in
   the README (the same check `build.sh` does).
4. Install it like any official update. Same care: UPS if you can, never switch off during the update.
5. After it boots, UTILITY > VERSION No. must show **1.87**, and the screens must be the stock ones.

Notes:

- The official update restores the stock firmware completely. In our tests on real hardware, future official updates
  then installed normally.
- If the update is skipped again, do DEFAULT once more and repeat step 4.
- The only thing that may remain is an entry in the settings log. A second DEFAULT clears it.
- The same steps are in `back_to_stock.txt`.

---

## Building

### Which way should I build?

There are two ways. Both give the same result, with the same sha256.

**Easy way: Cueline Builder.**

1. Download `CuelineBuilder.exe` (Windows) or the `cueline-builder` folder (any system with Python 3) from the
   project's Releases page.
2. Check its sha256 (see below).
3. Windows: drag `C2KNXS2.UPD` onto `CuelineBuilder.exe`, or double-click it and pick the file.
   macOS / Linux: run `python3 cueline_patch.py C2KNXS2.UPD`.
4. It writes `Cueline/C2KNXS2.UPD` next to your file and checks that its sha256 is the published one.

**Paranoid way: build from source with `build.sh`.**

- Needs Linux (Ubuntu 24.04 is the reference) or Windows 10/11 with WSL. On a Mac, use a Linux virtual machine or
  a Docker Ubuntu container.
- Install the tools listed in the README, then run `./build.sh C2KNXS2.UPD`.
- The output is `out-release/C2KNXS2.UPD`, with `verify.txt`, `bootcheck.txt` and `build.log`.
- Exit code **0**: identical to the reference build. **2**: built, but different bytes (other tool versions).
  **1**: error.

**Never install a build whose verify or boot check failed.**

### What do the sha256 checks mean?

A sha256 is a fingerprint of a file. If one byte differs, the fingerprint differs.

- **Your input:** the builder and `build.sh` refuse any file that is not the official 1.87 `C2KNXS2.UPD`.
- **Your output:** the README lists the sha256 of the finished Cueline update. The Builder checks it for you.
- **The Builder itself:** the README lists the sha256 of `CuelineBuilder.exe` and of its patch data. Compare them
  before you run it.

To check a file yourself:

- Windows (PowerShell): `Get-FileHash .\CuelineBuilder.exe -Algorithm SHA256`
- macOS: `shasum -a 256 CuelineBuilder.exe`
- Linux: `sha256sum CuelineBuilder.exe`

### The builder says "is not the official C2KNXS2.UPD 1.87".

You used another version, or a changed file. Download 1.87 again from Pioneer DJ / AlphaTheta and unzip it.

### `build.sh` says "missing tool" or "missing Python modules".

Install the tools with the `apt install` line from the README's **Requirements**.

### `build.sh` ended with exit code 2. Is it safe?

Your compiler or Python versions differ from ours, so the bytes differ. If **both** `verify.txt` and `bootcheck.txt`
passed, the build is safe to install. If either failed, do not install it.

### Windows SmartScreen or my antivirus warns about CuelineBuilder.exe.

`CuelineBuilder.exe` is not signed with a paid code-signing certificate. Windows SmartScreen and some antivirus
programs warn about every unsigned program that few people have downloaded yet.

- First check the exe's sha256 against the README. If it matches, the file is the one we published.
- SmartScreen: click **More info**, then **Run anyway**.
- If you prefer not to run the exe, use the Python script (`python3 builder/cueline_patch.py C2KNXS2.UPD`) or build
  from source. All three give the same sha256.

### Can an AI assistant build it for me?

Yes. The README has a prompt you can copy. The assistant should only build. It must never change, upload or share
Pioneer files, and never flash anything itself.

---

## Using Cueline

### Where do I see which version I run?

UTILITY > INFO > **BUILD** shows the build, for example `Cueline-2.3 2cd1c93f`. UTILITY > VERSION No. shows the version
number.

### Where are KEY SHIFT and KEY SYNC?

They are back in Cueline 2.3, with a new engine that works inside the deck's own MASTER TEMPO engine (as the
CDJ-3000 does). Turn on UTILITY > DJ SETTING > KEY SHIFT and tap the KEY SHIFT tile in the header. They were
switched off in 2.2 only: if you run 2.2, update to 2.3.

### Some of my settings go back to default after power-off.

- WAVEFORM (FULL / HALF), KEY FORMAT and the BEAT JUMP value are saved with the
  HISTORY NAME. They are only kept if your **HISTORY NAME is 29 characters or fewer**. Shorten it in UTILITY >
  SYSTEM > HISTORY NAME.
- The kill switches, BEAT NUMBERS and GRID ADJUST are **never** saved. They are ON at every power-on. This is on
  purpose.

### Link Cue makes no sound.

- You need a **DJM-A9** on Pro DJ Link, and its LINK CUE headphones.
- Only **MP3, FLAC and WAV** work. AIFF and M4A stay silent.
- Check that UTILITY > INFO > **LINK CUE** is BOTH (or PREVIEW) and **LINK ROW PREVIEW** is ON.
- Check that there is no file named `NOMODS` on your stick.

### The menus are not in my language.

Since 2.3 UTILITY > LANGUAGE offers English, French, German, Italian, Dutch, Spanish and Portuguese for the deck's
own texts. Cueline's own screens and the UTILITY item names stay in English. The other languages of the official
firmware (and the Chinese and Korean fonts) were removed to free space for the features.

### A track shows no waveform.

Tracks without rekordbox analysis play normally but show no waveform, overview or beat grid. Analyse and export the
track with rekordbox.

---

## When a feature misbehaves

### Turn the feature off with a kill switch (DEV build)

**The kill switches are shown in the DEV build only**; the RELEASE build keeps every feature ON and does not show these rows.

Go to **UTILITY > INFO** and scroll past VERSION No. Each row turns one feature back to the official behaviour,
right away:

| Problem with... | Turn OFF |
|---|---|
| KEY SYNC (tile or D/H pad) | KEY SYNC |
| Other decks reading our key | LINK KEY STATUS |
| Link Cue or Touch Cue | LINK CUE |
| Preview of other players' tracks | LINK ROW PREVIEW |
| The phase meter WAVEFORM view | MASTER WAVEFORM (and MASTER WAVE NFS) |
| The detail waveform drawing or scrolling | HW BAND LAYER |

Kill switches are not saved. Everything is back ON at the next power-on.

You can also put a file named `NOMODS` at the root of your stick. It turns off Link Cue and the browse-row preview
without reflashing.

If the problem stays, go back to stock (see above) and play your gig on the official firmware.

### How do I report a bug?

1. Note UTILITY > INFO > **BUILD** (for example `Cueline-2.3 2cd1c93f`).
2. If you run the DEV build, try the matching kill switch. If the problem goes away, say which one.
3. Open an issue on the project's GitHub page. Include:
   - the BUILD id;
   - your setup: the deck, the mixer, Pro DJ Link or not, other players and their firmware;
   - the file format of the track (MP3, FLAC, WAV, AIFF, M4A);
   - what you did, what you expected, and what happened;
   - a phone video, if you can. It helps a lot.
4. For bugs that are hard to catch, a contributor may ask you to install the **DEV build** (see `dev/README.md`). It
   has a BLACK BOX recorder and logs. The normal RELEASE build has no recorder, no logs and no network commander.

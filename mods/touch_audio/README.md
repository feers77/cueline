# touch_audio — Link Cue / Touch Preview for the CDJ-2000NXS2

The deck joins a DJM-A9's LINK CUE as a CDJ-3000 Touch Preview source and
lets you hear a track **before loading it**, on the mixer's headphones only.

## Use

1. On the mixer, press **LINK CUE** in the headphone section.
2. On the deck, **BROWSE** to a track list, highlight a track, press **INFO**.
   The overview strip at the bottom turns blue with that track's waveform.
3. **Hold a finger on the strip**: the track plays from that point on the
   LINK CUE. Drag to move, lift to stop. A white column marks the playing
   point. Scroll with INFO open to preview another track.
4. Leave INFO or the browser: the strip shows the loaded track again. The
   track on the deck is never moved (the strip's needle search is off while
   INFO shows a track).

**Touch Cue** (CDJ-3000 style): while the deck **plays**, hold a finger on
the strip outside INFO and the loaded track plays from that point on the
LINK CUE; the main output keeps playing untouched. Paused, the strip keeps
its stock needle search. Touch Cue needs the track to come from the rekordbox
export (its id is looked up in export.pdb); a file loaded from FOLDER has no
export row and gets no Touch Cue.

Formats: WAV (16/24/32-bit integer, 32-bit float, extensible), 44.1 or 48
kHz, mono or stereo, from a rekordbox export on the deck's own
USB/SD **or on a LINKed player's media** (the firmware mounts those over NFS
as D:..Z:); MP3 and FLAC too when the `tadec` blob is placed
(`CDJ_MAIN_TADEC=1`, see `mods/tadec/`). AIFF/AIFC is out for now: the
deck's updater silently skips a MAIN section above 0x902A00 bytes (the
S-record text; our routines in the code cave count about 1:1), and the AIFF
parser was the cheapest 350 bytes to give back. It comes back inside the
tadec blob (C, in the packed part of the image, which does not count), with
a "no Link Cue for this file" mark on the strip for the formats left out.

Media: the task keeps one export.pdb index for the "current medium" -- the
one the browser shows: the DB context's descriptor of the current list
(`*0x09437CD0` -> DBctx, `+4` the list side, `+0x6C50 + side*4` -> {medium*,
slot, kind}, medium `+8` = player: what the firmware builds the rows' artwork
keys from; the INFO track is one of that list's rows). The artwork request
entry 0 (stale across a list change: the first INFO on a LINKed list looked
the id up on the previous medium) and the browse medium descriptor
0x0B5125C0 (not {player, slot} on the deck) were both wrong -- see
re/ARTREQ_MEDIUM.md. A key counts once it has held 300 ms. Or the loaded
track's source for Touch Cue
(status +0x28 player, +0x29 slot). Keys are made canonical first (the own
player, or 0, is player 0; slot 0 is the own USB, else SD): one medium, one
key, or the index would be rebuilt every pass. While INFO shows a track the
loaded track is not reselected for Touch Cue (same reason). A list's medium
becomes current as soon as the list shows, so its index builds while the
user scrolls (a LINKed player's export over NFS takes seconds). A
medium's drive letter comes from the firmware's media records (0x0A35F80C +
player * 0x414 + slot * 0xA8: +4 the letter, +8 state 2 = present; player 0
= this deck; before the LINK is up the deck has no number and no status
packet, so every list and the loaded track count as the own medium, USB
first). Switching medium closes a LINKed medium's export.pdb (the own
medium's stays open: the firmware's database layer shares it) and rebuilds
the index for the new one; the DIAG value line ends with that letter.

## Mods

| Mod | Knob | Site | What |
|---|---|---|---|
| touchaudio | `CDJ_MAIN_TOUCHAUDIO` | DJCONT_PASS | spawns the `TchAud` task: device-17 "CDJ-3000" keepalive (own IP/MAC), A9 timing on UDP 50004, 7 ms audio packets; INFO/strip/touch handling, export.pdb lookup, PWAV strip, WAV/AIFF reader and 48 kHz resampler; Touch Cue = `tc_check` (V4n28t: back -- V3e2 had removed it with the INFO strip code; strip = touch zone 0's x0/y0/w/h, the V2 overview 79,405,640x75; not in a browse list nor INFO; loaded track via `rq_get`) |
| touchaudioip | `CDJ_MAIN_TOUCHAUDIOIP` | LINK_RECEIVE | learns the mixer's address from its keepalive |
| touchaudiotouch | `CDJ_MAIN_TOUCHAUDIOTOUCH` | strip touch handler 0x084EDC5A | no needle search on the strip while INFO shows a track (LINK CUE with PREVIEW), while the strip shows the task's waveform, or while Touch Cue plays (LINK CUE with CUE, a rekordbox track playing); stock otherwise |
| tadec (blob) | `CDJ_MAIN_TADEC` | code cave 0x08140000 | MP3 (dr_mp3) / FLAC (dr_flac) decoder the reader falls back to for files that are not RIFF/FORM; since V4n27 it runs in its own task **TchDec** (priority 11, created by TchAud on the first MP3/FLAC open, 48 KB stack + a 64 KB PCM ring from malloc, ~200 ms ahead): TchAud only copies frames out of the ring, holds + fades (10 ms ramps) when it is dry, and a seek plays the old position on until the new one is pre-rolled (tadec.c "TchDec"). TchDec reads its file only while TchAud allows it (row_waves calls q_quiet first) |
| touchaudiopack | `CDJ_MAIN_TOUCHAUDIOPACK` | frame packer 0x0838EB7A | packs the preview strip into the MAIN->GUI frame ahead of the player-model message: while a track plays the model is dirty nearly every frame and the stock packer then skips the strip, so the preview strip only showed once the deck paused |

The deck must be bridged onto the mixer's network. In the emulator, keep
`live_clock` on (`CDJ_GUI_CLOCK_DT=43`): without it the REMAIN clock only
repaints every couple of seconds under emulation.

## Firmware facts used (v1.87)

- INFO pop-up on a listed track: display mode `mem32[0x0A35F3CC] == 2`;
  its rekordbox id at `0x09437A6C`.
- Calibrated touch: x, y pixels at `0x0B06C774` / `0x0B06C778` (0 when up);
  strip = zone 0 of the touch table, (100, 377, 600, 103).
- Overview strip: 600 six-byte records at `0x0B569528` (two RGB565 colours,
  two 6-bit heights); lock `0x08404A38`, unlock `0x08404A5E`, dirty
  `0x0B56951C = 1`, link sender armed by `0x0A35F3F0 = 1`.
- Own IP: getter `0x08221D9E`; own MAC: `0x0A35F754`.
- Play mode `0x0A35F7A0` (3 playing, 4 looping, 5 paused: the status
  packet's byte). The deck's own status packet is kept at `0x0B53D828`:
  `+0x2A` track type (1 rekordbox, 2 file from FOLDER), `+0x2C` rekordbox id
  (big-endian). The load record at `0x0C27A350` lags one load behind: not
  usable for "the loaded track".
- File thunks: fopen `0x082C0D2A`, fseek `0x082C0D3C`, fread `0x082C0D44`;
  fclose is `0x082C0D56` (`0x082C0D34` is ftell: calling it as fclose leaks a
  handle per open, and opens fail after ~27). `export.pdb` must not be closed
  from the mod's task -- the firmware's database layer uses that file and its
  track loads then hang at NOW LOADING -- so the mod opens it once and keeps it.
- The INFO id at `0x09437A6C` reads 0 for a moment while the pop-up redraws.
- Diagnostics: `0x081FFE00` (last open: fopen, status, rate, bits/ch -- for
  MP3/FLAC the 16.16 step instead), `0x081FFE40` (export.pdb lookups: count,
  id, pdb handle, rows found, ANLZ handle, PWAV bytes, rows seen, last id;
  `+0x24` ANLZ fclose result), and the counters at `0x081FFE80` (zeroed when
  the task starts): `+0` 0x1e packets sent, `+4` with PCM, `+8` zero-filled,
  `+0x10` pacer resyncs (more than 28 ms behind), `+0x18` failed sends,
  `+0x1C` timing packets taken, `+0x20` election timeouts (no timing for 1 s),
  `+0x24` timings from an ip other than the mixer's (dropped), `+0x28` failed
  opens, `+0x2C` kill edges (MODS / LINK CUE turned off), `+0x30` lookups that
  waited for the index, `+0x34`/`+0x38`/`+0x3C` the rate's own state, `+0x40`
  strip redraws, `+0x44` strips packed ahead of the model (touchaudiopack).
- **UTILITY > LINK CUE DIAG** (mods/modsmenu) shows the same without any tool,
  in both columns of its row. Value column (about 18 characters visible, so
  no spaces): `E1T17R143X2S9` = the mixer's E (LINK CUE on) and T (17: this
  deck elected), packets per second (143 while previewing; 0 when idle), the
  export.pdb index state X (0 not started, 1 building, 2 ready, 3 failed --
  retried every 10 s), S = state bits (1 finger down, 2 track resolved, 4 the
  strip shows our waveform, 8 INFO on a track: 9 = INFO + finger), C = the
  inter-deck Link Cue claim (R22A: 0 this deck does not want the mixer's
  slot, 1 it holds the claim, 2 it wants it but the other Cueline deck holds
  it, so this deck is silent). Label
  column (the task rewrites the item's label): `M0 Y0 W0 A0` = election
  timeouts (M: one per preview the mixer let go, benign), pacer resyncs (Y:
  stalls over 84 ms), strip redraws (W: the deck overwrote the preview
  strip), strips packed ahead of the model (A: while playing); each capped
  at 999. The value line ends with the current medium's letter.
  Refreshed every 500 ms; the row redraws when the menu does.
- **Pacing**: one audio packet per timing packet from the mixer (its 48 kHz
  clock, 7 ms); the deck's own 1 ms tick paces only while no timing arrives
  (the engage packets before the election, a mixer gone). Pacing by the tick
  drifted against the mixer and made a dropout every few seconds on the deck.
  Up to 12 due packets go out back to back after a stall; beyond that the
  backlog is dropped and one packet goes out (Y).

## Robustness (how the task behaves on a real deck)

- The export.pdb **index** (track id -> page) is always built, a few pages a
  pass, whether or not the rowwave mod is present; until it is ready a lookup
  (INFO, Touch Cue, a browse row) waits and is retried on the next pass
  instead of walking the whole table. Only a failed index walks.
- Turning **MODS** or **LINK CUE** off closes the preview *and forgets the
  track*: the next press opens it again (before, the task kept thinking the
  file was open and streamed silence for good).
- A track whose ANLZ has **no PWAV** still plays; the strip shows a flat band.
- The deck rewrites the overview strip on its own (a load, the GUI asking
  again while the deck plays): the task checksums three records of what it
  drew and redraws the preview strip as soon as they change (W counter).
- **WAV** chunks are walked with fseek: a `data` chunk behind large `bext` /
  `iXML` / `LIST` / `ID3 ` chunks (rekordbox exports with embedded artwork)
  is found; `fmt` and `data` may come in either order.
- A short read (the end of the track) is silence, never the stale buffer;
  a preview ends where the track ends (no wrap).
- While elected and idle (no finger down) the task sends nothing (the
  behaviour proven on the deck). A CDJ-3000, observed running
  (re/LINKCUE_3000_LIVE_1121.md): nothing before its first request, even
  when already elected; after a request it answers EVERY timing packet for
  as long as it keeps the channel, with zero PCM when no preview sounds --
  a later step for us. Without a timing packet for 1 s it counts itself not
  elected again (the zero packets then carry I=1, the engage request);
  timing is taken only from the mixer's ip (the one its keepalive announced).
- **Two Cueline decks, one Link Cue slot (R22A).** The device byte 17 is the
  Pro DJ Link slot the mixer registered as a Link Monitor source, so both
  decks use it and both read the mixer's `T == 0x11` as "I am elected" -- with
  both engaged at once they interleaved their audio. The decks therefore
  arbitrate between themselves, and the rule (the owner's) is **the holder
  keeps it**: while one deck holds the claim the other one does not take it
  even if its user engages it, it simply stays silent, so an accidental touch
  on the other deck can never cut the preview you are listening to. To switch
  you lift and touch the other deck.
  `ca_pub` keeps this deck's claim at `RAMB + 0x1E780`: `+0` the ms since we
  took it (0 = we hold nothing, and this is what goes on the wire), `+4` the
  state (0 idle, 1 we hold it, 2 we want it but the other deck holds it),
  `+8` the tick we took it. `mods/keyshift` `kx_send` puts
  `{'CLC1', the age big-endian}` at `0x170` of our own 0x180-byte status
  packet, but only towards another Cueline deck (class 2), and `ks3k` stores
  each peer's `{age, arrival tick}` at `RAMB + 0x1E7A0 + player * 8`.
  `ca_scan` decides: a peer's claim counts only while its status keeps
  arriving (**1 500 ms**, ~5 status periods -- a deck that is powered off,
  unplugged, crashed or off the LINK loses the slot by itself, which is why
  it can never stick), the holder keeps the slot, and two claims taken within
  250 ms of each other (the same instant, or one deck booting before it had
  heard the other) go to the lower player number, which both decks decide
  identically. `sa_silent` is the single word every sender reads: a deck that
  does not hold the claim sends no audio and no engage packet, and while it
  *wants* the slot that the other deck holds it stops its keepalive too. An
  idle deck keepalives as in 2.1, so the slot stays registered with the mixer
  and a hand-over costs no re-registration -- the delay the owner reported in
  2.1.1.
- Formats are refused rather than overrun: MP3/FLAC above 48 kHz (a packet's
  source frames would not fit the raw buffer) and M4A/AAC (by the export
  row's file type; dr_mp3 would scan the whole file for a sync).
- While a preview streams, the task does no other file I/O (no index
  building, row lookups or artwork): every read there is a packet late. A
  table walk with a failed index is spread over passes (48 pages a call).
  Short reads (NFS) are retried next pass, never taken as data; the MP3/FLAC
  reader (tadec) fills its 64 KB requests across the NFS short reads (one
  READ of 8 KB per call on the deck) instead of taking them as the end.
- A medium that goes away (USB pulled or swapped) drops its index and its
  kept export.pdb handle; the next use reopens. Touch Cue remembers the
  loaded track's medium with its id (ids repeat across exports).
- Without a mixer, `scripts/net/fakea9_mcast.py` plays one on the emulator's
  multicast segment (keepalive, 7 ms timing, records the 0x1e packets and
  their PCM; see the two-deck network recipe for the emulator's `-netdev`).

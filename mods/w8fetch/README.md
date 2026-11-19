# w8fetch — the TEMPO MASTER's waveform for the phase meter (W8)

CDJ-3000 style phase meter, WAVEFORM type: the master deck's own waveform
scrolls in the meter. MAIN fetches the master's detail waveform (PWV5) and
beat grid (PQT2, from the .EXT) over Pro DJ Link and sends them to the display as message
0x31; the display keeps them in free SDRAM for the V2 renderer
(`mods/v2ui/v2.c`, `master_mini()`). The drawing itself is not part of this
mod.

Opt-in: name `w8fetch` (mods.conf row: `w8send` + `w8cap` MAIN, `w8recv`
GUI). All three are in their image's `OPT_IN`, so builds without it are
byte-identical to before.

## MAIN

- `main_w8send.s` (replaces the frame packer's last sub-packer call
  0x0838EC76..0x0838EC86, repeating it first; normal path only — the update
  stream is mode 2 and never gets there): every frame it reads the master
  from the heartbeat model (0x0B568C9C +0xA4, not this deck's +0x5C) and what
  it plays from MAIN's LINK status table (0x0A371D3C + player * 0x124: +0x28
  source player / slot / type, +0x2C rbid; rekordbox tracks only). On a new
  target: control record invalid → DB request (code 0x433, the stock CUEWAV
  requester's PWV5 fetch, through 0x084A009A to the DB task's mailbox
  *0x09435CC8, tid = {source player or 0 for this deck's own media, slot,
  type, rbid}, reply mailbox W8MBX = 0x5738) → stream PWV5 → stream grid →
  control record valid. Chunks go through the stock chunk sender 0x083913C2
  (type 0x31, ≤ 0x2000 B a frame, only when the frame has room), charged as
  the stock detail packer charges its own.
- `main_w8cap.s` (replaces 0x0827C2CA..0x0827C2D8 in the DB task's common
  reply sender 0x0827C2C4): a reply to a request whose mailbox is W8MBX is
  not mailed; its PWV5 block is kept and, still in the DB task, the same
  track's PQT2 is fetched (open 0x0827A228 / tag 0x082545F8 "PQT2" "EXT" /
  close 0x0827A34E; the stock grid parser 0x0826AFDE reads PQT2 too, for
  local and LINKed loads; a "PQTZ"/"DAT" fetch answers with no data); both are handed to w8send, the reply block released.
- State: 128 B at RAMB+0x1E000 (w8.inc).

## NFS fallback (V4n31, #34)

A CDJ-3000 master's dbserver answers the 0x433 PWV5 (and w8cap's PWV7) request
empty. Then -- or when no reply came in 10 s -- and the master plays from a
LINKed medium, w8send (ST 5) asks touch_audio through W8N (W8S + 0x80, see
w8.inc): its TchAud task (row_waves pass, `w8n_step`, after q_quiet; normal
boot only; never during a preview) makes the master's medium the export.pdb
index's medium (not while a list / INFO shows, an index builds or rv_cue needs
the current one), looks the rbid up (tp_resolve, TP_RW = -3 -> `tr_w8n`),
reads PQT2 + PWV5 from the .EXT over the firmware's NFS mount (D:..Z:) and
answers with blocks shaped like w8cap's. The DB task never touches NFS;
w8send gives up after 60 s (cancels: KEY 0) and frees late answers.
Bench: work/v4n/w8n (W8EMPTY test build of w8cap = every DB answer empty).

## Message 0x31

`[seq][0x31][len u16][last u16][index u16]` + payload (≤ 0x2000 B).
`index = kind << 14 | chunk` (chunk 1-based), `last` = the stream's last
index. Kinds: 0 PWV5 entries, 1 grid (PQT2 tag), 2 control record. Order:
control (valid 0) → PWV5 chunks → grid chunks → control (valid 1). A new
target restarts with a control (valid 0) at once; a stream in progress is
abandoned (its later chunks are never sent). The stock GUI ignores 0x31.

## GUI buffer (w8recv, SDRAM 0x0CA00000-0x0CA90000, big-endian)

Hook on the message dispatcher 0x0E50112C after its header copy. Range from
re/PERF_BROWSE_PLAY.md §7.2 (0x0C850000-0x0CD00000 zero / unused in V3e1;
0x0C900000 is v2.c's phase-meter scratch frame, not touched).

| address | size | content |
|---|---|---|
| 0x0CA00000 | 4 | magic `'W8M1'` (0x57384D31), written by the receiver on each control record |
| 0x0CA00004 | 4 | valid: 1 = PWV5 (and the grid, when it has one) of the target below are complete |
| 0x0CA00008 | 4 | key: master player << 24 \| type << 16 \| slot << 8 \| source player (0 = the master plays from THIS deck's media) |
| 0x0CA0000C | 4 | rbid of the master's track |
| 0x0CA00010 | 4 | PWV5 bytes (= entries × 2); 0 while not loaded |
| 0x0CA00014 | 4 | grid bytes streamed (the PQT2 tag length rounded up to 4, at most 0x7FFC); 0 = no grid |
| 0x0CA00018 | 8 | 0 (reserved) |
| 0x0CA0003C | 4 | receiver's count of control records (changes on every target change and when it becomes valid) |
| 0x0CA00040 | ≤ 0x60000 | PWV5 entries: u16 big-endian, exactly as in the ANLZ file / as the stock detail buffer (`*0x0E5EB088`): R 15-13, G 12-10, B 9-7, height 6-2; 150 entries a second |
| 0x0CA80000 | ≤ 0x8000 | the PQT2 tag exactly as in the .EXT (big-endian): +0 `'PQT2'`, +4 header len 56, +8 tag len, +12 0, +16 0x01000002, +20 0, +24 first beat `{u16 beat in bar, u16 BPM × 100, u32 time ms}`, +32 last beat (same form), +40 u32 beat count n, +44 u32 ?, +48 8 × 0, +56 n × u16 per-beat entries (packed deviations, not decoded) |

Reading it (v2.c): use the uncached mirror (`| 0x20000000`) as for the other
DMA-filled buffers. Draw only when `valid == 1`, `magic` matches and
`key >> 24` is the heartbeat's master (+0xA4); otherwise the buffer is stale
or being refilled. `master_mini()` can pass `(u16 *)0x2CA00040` and
`n = pwv5_bytes / 2` to `col_prof()` like its own detail. The master's beat
`b` (1-based) for a constant-tempo grid (rekordbox's usual; the stock grid
check is the same): `t(b) = t1 + (b - 1) * (tn - t1) / (n - 1)` ms with t1 /
tn the first / last beat times at +28 / +36 (checked on the bench: 125.00
BPM, 941 beats, 2 .. 451,204 ms; 123.00 BPM 427 + 777 x 487.8 = 379,451).
Limits: 0x30 chunks of PWV5 (196,608 entries ≈ 21.8 min; later chunks are
dropped by the receiver) and 4 of grid (MAIN clamps it at 0x7FFC bytes).

## Notes

- The 0x433 handler is the stock one, so `three_band`'s `wave3data` (hooked
  inside it) also runs for our request: it fetches the master's PWV7 and
  swaps the hand-over word 0x081FFFF4 (it frees the previous track's packed
  words). The deck's own load reads that word right after its own reply, so
  only a W8 request handled between the deck's own reply and its conversion
  would matter (see the W8 report).
- Byte order: the chunk sender's copy for types > 40 plus the link hand the
  display each 32-bit word's value; byte data arrives with each 4 bytes
  reversed and the receiver reverses them back (control words are copied as
  they are).

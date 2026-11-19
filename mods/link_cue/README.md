# link_cue (prototype)

The first piece of Link Cue (the CDJ-3000 feature) for the CDJ-2000NXS2: a deck
reads a stretch of **another player's track over Pro DJ Link** and streams it
out in real time, without disturbing its own playback.

This prototype is a file streamer. The deck opens and reads the file;
the client does any decoding. `lc_client.py` handles WAV, AIFF/AIFC
(byte-swapping AIFF's big-endian samples) and, by piping the compressed
bytes through ffmpeg, FLAC and MP3. Compressed seeking is by byte offset
from the average bitrate, so the preview lands near the asked time, not
frame-accurate. Sending the audio to a DJM's LINK CUE input in
the mixer's own format is the next step; it needs a capture of that
protocol first.

| knob | value | what |
|---|---|---|
| `CDJ_MAIN_LINKCUE` | `1` | the hook and the streamer task (MAIN firmware v1.87) |

`mods.conf` row `link_cue`, off by default.

## How it works

- **Hook**: `DJCONT_PASS`, the DJcont output loop, the same site as `tcnet`.
  After 1000 passes it creates the RTOS task `LnkCue` once (`acre_tsk`
  0x085142D8 and `sta_tsk` 0x08514730, priority 9) and then does nothing
  more. The task's 4 KB stack and its packet buffers come from the
  firmware's `malloc` (0x08344A9C).
- **Task**: opens UDP 50099 with the firmware's own UDP layer
  (`udp_vcre_cep`, `udp_rcv_dat`, `udp_snd_dat`, as `tcnet`), then polls it.
- **Files**: the stdio wrappers of the firmware's file library:
  `fopen` 0x082C0D2A (UTF-16 path), `fseek` 0x082C0D3C,
  `fread` 0x082C0D44, `fclose` 0x082C0D34.
  - `C:` is the deck's own USB.
  - `D:` is the USB of the player on the other end of Pro DJ Link, which the
    firmware's VFS mounts over NFS. That is how a deck already plays a
    LINKed track: loading one from player 1 opens
    `D:/Contents/<artist>/<album>/<file>`.
- **Pacing**: the 1 ms RTOS tick (0x0B0C5258) against a rate in bytes/ms
  (16.16 fixed point), plus a lead.

## Protocol (UDP, little-endian)

Request to the deck, port 50099:

| @ | field |
|---|---|
| 0 | `"LCQ1"` |
| 4 | file offset |
| 8 | bytes to stream; 0 stops the current stream |
| 12 | bytes per packet, at most 1400 (0 = 1400) |
| 16 | pace in bytes/ms, 16.16 fixed point; 0 = unpaced |
| 20 | lead: bytes allowed ahead of real time |
| 24 | path, UTF-16LE, NUL-terminated |

A new request replaces the stream in progress. Each reply goes to the
requester:

| @ | field |
|---|---|
| 0 | `"LCD1"` |
| 4 | sequence number |
| 8 | file offset of the data |
| 12 | data bytes that follow; 0 = end, -1 = open failed, -2 = seek failed |
| 16 | data |

## Client

`lc_client.py` joins the rig's Pro DJ Link segment as a host of its own
(QEMU's multicast netdev, `GROUP`), answers ARP and talks to the deck. On a
real network the same requests work from any PC on the Pro DJ Link LAN.

```sh
# two linked decks with the mod
CDJ_MAIN_LINKCUE=1 ./start.sh
# 10 s of player 1's track, read through player 2 over the link
python3 mods/link_cue/lc_client.py --deck 192.168.50.11 \
    --path "D:/Contents/UnknownArtist/UnknownAlbum/SS - Innerbloom Rmx.wav" \
    --at 60 --secs 10 --out preview.wav --play
```

## Verified in the emulator (two linked decks)

- **`C:` and `D:` both work.** Streaming from the remote USB through `D:` sent
  10 s of 24-bit, 44.1 kHz audio in 1890 packets with none lost. The result is
  **bit-identical** to the source file.
- **Pace and errors.** Paced, the stream ran at 1.00x real time while the deck
  played its own track, and the firmware logged no errors (`DJcont … timeout`,
  `ErrEnd`, E-codes).
- **Load in the emulator.** Two decks already run the emulator at 0.93x real
  time. A paced stream takes that to about 0.78x, and an unpaced one to 0.68x.
  How much of this is the guest's CPU and how much is NIC emulation in QEMU is
  not measured; on hardware, the task's priority 9 is below DJcont's 6.
- **Idle deck.** With no track playing, `icount sleep=on` warps the virtual
  clock ahead, so the pace runs fast (about 1.4x). This only happens in the
  emulator.

## Not done yet

- AAC/ALAC and other formats ffmpeg does not get as a raw stream. WAV, AIFF,
  FLAC and MP3 work. On a separate test stick with two linked decks, 8 s of a
  16- and a 24-bit AIFF read through `D:` match ffmpeg byte for byte. FLAC and
  both CBR and VBR MP3 are checked against a local deck simulator
  (`re/comptest/local_deck_test.py`): size probe, stream and decode are
  lossless versus ffmpeg of the same bytes.
- **Repeated opens of a `D:` (NFS) file leak the firmware's file handle**: the
  streamer's `fclose` returns but the remote handle is not freed, so after
  about six opens `fopen` on `D:` fails until the deck reboots. A `C:` (local)
  file is fine. The client now treats a failed seek past EOF as end-of-file in
  its size probe, but the deck should cache the open handle per path so one
  preview is one open, not dozens. Until then, keep previews few, or prefer `C:`.
- The DJM LINK CUE output format.
- A trigger from the deck's own UI (touch or keys).
- A test under the Sh4 interpreter (`tests/test_main_osc.py` style).
- Mapping the drive letters for other players and slots (SD, players 3-4).
- Measuring the CPU cost on real hardware.

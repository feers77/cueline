# wav32 — 32-bit WAV playback for the CDJ-2000NXS2

The deck's native play path accepts only PCM WAV at 16 or 24 bits. This mod
makes it **load and play 32-bit WAV files** — 32-bit integer, 32-bit float,
and WAVE_FORMAT_EXTENSIBLE (0xFFFE) wrapping either — by presenting them to
the rest of the firmware as ordinary 24-bit PCM and converting the samples on
the fly as the play engine reads them. 16/24-bit EXTENSIBLE PCM is accepted
too. Nothing downstream of the parser changes: duration, waveform, tempo and
the read/seek machinery all see a normal 24-bit stream.

This is the **play path** (what comes out of the deck's outputs), independent
of `touch_audio`, which has its own reader for the LINK CUE preview.

| knob | value | what |
|---|---|---|
| `CDJ_MAIN_WAV32FMT` + `...DATA` + `...FO` + `...SEEK` + `...RD` + `...RDEND` | `1` | the six parts below |

`mods.conf` row `wav32`. Turned off at runtime by the **WAV 32-BIT** item in
UTILITY (or `C:/NOMODS`): the `TchAud` task writes the kill word `"NOMO"` to
`RAMB+0x1F7E8`, which `wav32fmt` tests, and 32-bit files then fail to load as
they do on stock.

## How it works (6 parts, SH-4 LE, firmware v1.87)

All sites are located by **byte signature**, not hard offset, so they survive
build-to-build displacement. Addresses below are the stock v1.87 sites — the
starting point for re-locating them on another firmware (e.g. NXS1).

| Part | File | Stock site | Role |
|---|---|---|---|
| 1 | `main_wav32fmt.s` | `0x08348D50` (fmt-tag fetch) | Accept tag 1 (int32) / 3 (float32) / EXTENSIBLE sub-format 1 or 3. Rewrite the `fmt ` chunk **in the parser's own read buffer** to look like 24-bit PCM (bits=24, tag=1). Record the source format in the shared block (`RAMB+0x1FF00`: 1=int32, 3=float32). |
| 2 | `main_wav32data.s` | `0x08348F8A` (chunk-walk "data" compare) | For a 32-bit source, scale the `data` length ×3/4 (so sample/duration/block counts describe the 24-bit stream) and append a record `{data offset, file size, format}` to the ring at `RAMB+0x1FF00`. |
| 3 | `main_wav32fo.s` | `0x082F1940` (play-path file-object build) | Match the recorded track by (data offset, file size). Restore the **real** data length (×4/3, via reciprocal `0xAAAAAAAB`) into the file object, and mark the `FILE *` in the active-file ring `RAMB+0x1FF48` so the read/seek hooks recognise it. |
| 4 | `main_wav32seek.s` | `0x082D61C4` (play-path seek) | For a marked file, scale the incoming 24-bit offset ×4/3 to the real file offset (sign preserved). |
| 5 | `main_wav32rd.s` | `0x082D62AC` (play-path read entry) | For a marked file, request ×4/3 as many bytes (always a whole number of 4-byte source samples). |
| 6 | `main_wav32rdend.s` | `0x082D633C` (right after `fread`) | Pack the 4-byte samples in the buffer in place to 3-byte 24-bit LE: **int32** keeps its top 3 bytes; **float32** is scaled by 2^23 and clipped to `0x007FFFFF`. Fix the byte counts (read and asked) back to ×3/4 so the engine's own short-read test still holds. |

### Shared state (stock layout, `RAMB = 0x081E0000`)
- `RAMB+0x1FF00` — parse/record block: `+0` source format of the file being
  parsed, `+4` ring index, `+8` four records `{data offset, file size, format, 0}`.
- `RAMB+0x1FF48` — active-`FILE *` ring: `{idx, 4×{FILE *, format}}`.
- `RAMB+0x1F7E8` — kill word; `"NOMO"` (0x4F4D4F4E) when WAV 32-BIT is off.
- Constants: reciprocal for ÷3 = `0xAAAAAAAB` (`x/3 = (x*0xAAAAAAAB)>>33`);
  int24 clip = `0x007FFFFF`.

### float32 → int24 (part 6)
Assemble the IEEE-754 bits, `shift = 127 - exponent`; `shift <= 0` clips to
`0x007FFFFF`; `shift >= 24` gives 0; otherwise form `(1.mantissa) << 8` with
the implicit bit and arithmetic-shift `>> (shift+8)` to 0..0x7FFFFF, then apply
the sign. Stored little-endian, 3 bytes per sample.

## Status

Unit-tested on SH-4 (qemu-user) and confirmed in the emulator: both a 32-bit
integer and a 32-bit float test file load and play. Not yet heard on real
hardware audio (the emulator has no audio path). Tag `wav32-v1`.

## Porting to another deck (e.g. NXS1)

The logic is firmware-independent; only the six stock sites and the three
shared-block offsets need re-deriving on the target. All six hooks key off the
same `RAMB+0x1FF00` / `+0x1FF48` / `+0x1F7E8` convention, so once the parser
fmt/data sites and the play-path file-object/seek/read/post-fread sites are
found, the `.s` sources port with address changes only. The WAV container
layout (fmt `+8` tag, `+22` bits, `+24` EXTENSIBLE sub-format GUID; "data" id)
is the same across decks.

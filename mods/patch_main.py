#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Apply code mods to the unpacked MAIN firmware image.

    usage: patch_main.py <main_unpacked.bin> <patched.bin> <mod> [<mod>...]
           patch_main.py --flash <flash.bin> <patched-flash.bin> <mod> [<mod>...]
           patch_main.py --assemble     rebuild every mod's .bin from its .s
           patch_main.py --list

Same shape as patch_gui.py (see that file for the general mechanism), on the
MAIN image instead of the display one. Two differences follow from MAIN being
executed in place rather than scattered to RAM by a load table:

  1. There is no scatter-load record to add: a mod's routine is written
     directly into a run of erased flash within MAIN's own address space
     (see sigpatch.place_inplace()), which is both its storage and its
     execution address.
  2. --flash patches the MAIN application's packed image directly inside a
     flat NOR/flash buffer (extract/flash.bin, or a deck's own copy), at the
     flash offset make_flash.py places it -- for booting a patched MAIN
     through Pioneer's own bootloader (MAIN_BOOT=flash) rather than via
     -kernel. The window each update is allowed to write is erased first, the
     same way the real updater erases before it writes, so a shorter or
     longer re-encoded stream never leaves stale bytes past its own end.

MAIN is a little-endian SH-4 (the GUI's SH7269 is big-endian), so every mod's
sig/args/literal is still given as the instruction's logical value -- see
sigpatch.ImageProfile's byteorder field, which does the translation.

Most MAIN mods are hooks (Mod.hook): several of them can sit on one firmware
site, which is defined once below and shared by every mod on it. The patch
engine moves the site's span into one trampoline that runs it once and then
calls each selected mod's routine in registry order -- see
sigpatch.trampoline() for the code and the contract a hook routine follows.
"""
import glob
import re
import struct
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIRMWARE = os.path.join(HERE, '..', 'scripts', 'firmware')
sys.path.insert(0, HERE)
sys.path.insert(0, FIRMWARE)
import sigpatch
from sigpatch import Mod
import main_decode
import main_encode
from main_flash import MAIN_END as FLASH_WINDOW_END   # V4n41: ours (was the emulator's make_flash.py)

# The 938,112-byte run of erased flash at file offset 0x11AF80 (address
# 0x0811AF80-0x08200000), found by the same erased-flash scan
# that found the GUI board's cave. Confirmed here, independently of that
# scan, by decoding every mov.l/mov.w @(disp,PC) instruction in the whole
# image (the same check sigpatch.literal_pool_reads() runs before every
# patch) and finding none of their targets inside this range.
MAIN_PROFILE = sigpatch.ImageProfile(
    flash_base=0x08000000, loadtab_off=0, loadtab_n=0,
    ram_base=0x0811AF80, ram_end=0x08200000, byteorder='<')

# The beat loop's call to the UDP send wrapper: the wrapper's literal, the
# port store into the send descriptor at r15+0x150, the descriptor pointer
# into r5 and the call itself with its delay slot. The beat packet the call
# sends stays reachable after it at *(r15+0x218), r12 still holds the
# wrapper and r10 the fpscr mask the firmware applies before every call.
BEAT_SEND = dict(
    sig=[0x0FC4, 0x7004, 0xDC2E, 0x0F26, 0xE254, 0x4208, 0x352C, 0x026A,
         0x22A9, 0x4C0B, 0x426A, 0x026A, 0xD62A],
    start=2,
    end=11,
)

# The USB-MIDI task's event loop, at its top: the task-state read, the load of
# that state's event mask into r14 and the push of the infinite timeout, all
# before the wait call. Every pass of the loop branches back to the start of
# the span; nothing after it reads r0 or r1 before the wait returns.
MIDI_TASK = dict(
    sig=[0xDAAE, 0xD1AE, 0x6012, 0xE1FF, 0x4008, 0x0E9E, 0x2F16, 0xE601,
         0x67C3, 0x55F3, 0x6452, 0x4A0B, 0xE5FF],
    start=1,
    end=7,
)

# The 1 ms timer interrupt's body (TMU unit 1 channel 1, the tick word
# 0x0B0C5258), at the first of its down-counters: the load of its base, the
# decrement unless already zero and the store. pr is saved before it, r1 is
# not read before the body next writes it and T is set again before it is
# tested.
TIMER_TICK = dict(
    sig=[0xD67E, 0x6262, 0x2228, 0x8B01, 0xA22C, 0x0009, 0xD67C, 0x5261,
         0x2228, 0x8901, 0x72FF, 0x1621, 0xD47A, 0xE5FF],
    start=6,
    end=12,
)

# The Pro DJ Link receive task, right after udp_rcv_dat has filled its 128-byte
# buffer (r10) and the call that takes a memory block for the datagram: the
# block call with its delay slot and the fpscr read that follows it. r0 still
# holds the block call's result, r14 the datagram length, *(r15) the block and
# r15+12 the sender's address; the stock test of r0 after the span loops back
# to the receive when it is non-zero, so a hook that sets r0 swallows the
# datagram.
LINK_RECEIVE = dict(
    sig=[0x26C9, 0xAFE4, 0x466A, 0xD25C, 0x65F3, 0xD75C, 0xE6FF, 0x470B,
         0x6422, 0x016A, 0x2008, 0x21C9, 0x8FD9, 0x416A, 0xD758, 0xE500,
         0x64F2, 0x470B],
    start=3,
    end=10,
)

# The Sentinel task's one call to the status serialiser: the argument offset,
# the serialiser's literal, the call with its delay slot and the two
# instructions after it (the fpscr read and the next literal load, which make
# the span long enough for the jump to the trampoline), between context
# halfwords that make the signature unique. The hooks run after the span; r11
# still holds the deck's own status record and r12 the fpscr mask the firmware
# applies around every call.
STATUS_SEND = dict(
    sig=[0x018C, 0x0B14, 0xE07E, 0x4008, 0xD33E, 0x430B, 0x04FE, 0x046A, 0xD131],
    start=2,
    end=9,
)

# The DJcont output task's loop (the task at 0x082D86AC), after the call that
# recomputes the play position word 0x09947488 from the DSP's frame: the call
# of its DSP-output step with its delay slot and the fpscr reads around it.
# The loop branches back to its wait right after the span, and nothing
# branches into it. r13 holds the DJcont record, r14 the fpscr mask; r6, the
# mask the loop applies on the way back, comes from the block.
DJCONT_PASS = dict(
    sig=[0xB015, 0x64D3, 0x056A, 0x64D3, 0x25E9, 0xD38F, 0x430B, 0x456A,
         0x066A, 0x26E9, 0xAFD2, 0x466A],
    start=2,
    end=10,
)

# The colour-preview publisher's copy of the 600 six-byte overview records
# into the link slot: the copy's call with its delay slot, then the fpscr read
# and the load after it, which make the span long enough for the jump to the
# trampoline. The hooks run after the copy, with the slot's lock still held.
OVERVIEW_PUBLISH = dict(
    sig=[0x65B3, 0xEB00, 0x2E12, 0xD14E, 0x410B, 0x1E21, 0x026A, 0xD547, 0xD644],
    start=3,
    end=8,
)

# The waveform requester's success path after the firmware has re-encoded the
# builder's PWV5 record: the free of the builder's record, then the stores of
# the new record and its size into the shared context (0x0B531EB8/0x0B531EBC).
# The hooks run after the stores and before the record is published. The only
# branch into the span is the `bf` just before it, which lands on its first
# halfword.
DETAIL_CONVERTED = dict(
    sig=[0x8B08, 0xD67E, 0x4A0B, 0x2F66, 0x096A, 0x57F7, 0x2979, 0x496A, 0xA00C,
         0x7F04, 0xD178, 0xDA7A, 0x4A0B, 0x5417, 0xD276, 0x0B6A, 0x5CF4, 0x5DF3,
         0x2BE9, 0x12C7, 0x4B6A, 0x12D8, 0x65F2, 0xD675, 0x460B],
    start=10,
    end=22,
)

# The colour-preview reader's call to the PWV4 tag reader, from the push of
# the tag's entry count to the argument setup before the call: the span has no
# branch and nothing branches into it. r13 holds the open ANLZ handle and the
# saved r5 the track's hash, both the reader's own arguments; the hooks run
# before the reader, which is before the preview is published.
PREVIEW_READ = dict(
    sig=[0x60E3, 0x8801, 0x8F0F, 0x426A, 0xE805, 0x4818, 0x78B0, 0x2F86,
         0x67F3, 0x66F3, 0x55F2, 0x7714, 0x7618, 0xB25E, 0x64D3, 0x0C6A,
         0x2CA9, 0x4C6A, 0x7F04, 0xDE7E],
    start=4,
    end=13,
)

# The browse list parser FUN_084C958C's two calls (0x084EB2D6 and 0x084EBA64,
# each through r7 loaded from a literal): the span loads r7 and the parser's
# arguments and makes the call with its delay slot; hooks run after the parser
# has filled the row slots at 0x0B5434EC.
LIST_PARSE_A = dict(
    sig=[0x456A, 0xE03C, 0xD732, 0xDD26, 0x06FD, 0xE040, 0x05FD, 0xE05C,
         0x470B, 0x04FE, 0x0A6A],
    start=1,
    end=10,
)
LIST_PARSE_B = dict(
    sig=[0xA121, 0x0009, 0xE040, 0xD761, 0xE600, 0xDD61, 0x05FD, 0xE05C,
         0xEE04, 0x470B, 0x04FE, 0x0A6A],
    start=2,
    end=11,
)
# The UTILITY list builder's 8-row loop (0x084F0914-0x084F09CC): the span is
# the slot-1 formatter call (jsr @(28,r12)) with its delay slot, surrounded by
# enough context to be unique. utiltint runs after it -- the row's text is
# already filled -- and before the grey block at 0x084F09A6, so a disabled
# row's grey store still wins. r15 is the builder's frame: *(r15+32) the item
# table base, *(r15+48) this row's offset into it, *(r15) its namebuf (slot +
# 0x0C). See mods/utiltint/main_utiltint.s.
UTILITY_ROW = dict(
    sig=[0x470B, 0xE500, 0x0B6A, 0x52C7, 0x64C3, 0x65F3, 0x2BD9, 0x420B,
         0x4B6A, 0x026A, 0x22D9, 0x426A, 0x52C5, 0x2228, 0x8B03],
    start=3,
    end=9,
)

# W8 (mods/w8fetch): the MAIN -> display frame packer's normal path, its last
# sub-packer call (0x083904A8, the fourth after the detail waveform's
# 0x08390148) with the fpscr masks around it, 0x0838EC76-0x0838EC86. The
# dirty-model frames branch past the span to its end; r1 is reloaded and
# r6/r7 rewritten right after it.
FRAME_PACK = dict(
    sig=[0x056A, 0x25E9, 0xD336, 0x430B, 0x456A, 0x066A, 0x26E9, 0xD335,
         0x430B, 0x466A, 0x076A, 0x27E9, 0x476A, 0xD124, 0xE20E],
    start=5,
    end=13,
)
# W8: the DB task's common reply sender 0x0827C2C4(reply, request), after its
# three pushes: the literal load, the moves into r13/r14 and the client
# check's call (0x0827C2CA-0x0827C2D8).
DB_REPLY = dict(
    sig=[0x2FD6, 0x2FE6, 0x4F22, 0xD620, 0x6D43, 0xD120, 0x6E53, 0xE501,
         0x410B, 0x6462, 0x076A, 0x2008],
    start=3,
    end=10,
)

# LINK0B (v4.2): the Pro DJ Link 50001 receive task (0x08511514): its recvfrom 0x08217A9E into the fixed buffer
# 0x0BFBB5F8 with the two pushes before it and the fpscr restore after it (0x085115F6..0x08511610), between the
# loop's literal load and its length test. The loop branches back to the span's first halfword only. After the
# span r0 = the datagram's length; the stock switch on byte 0x0A that follows has no case for 0x0b (dropped).
BEAT_RECV = dict(
    sig=[0x1375, 0x7AC0, 0xD99D, 0x2F86, 0x7FFC, 0xE700, 0x64C3, 0x6DF3, 0x65B3, 0x66A3, 0x7D18, 0x490B,
         0x2FD2, 0x016A, 0x21E9, 0x416A, 0x4015, 0x8FF0, 0x7F08, 0xD196],
    start=3,
    end=16,
)

# keyshift's ks3k (V4a3): the status receive 0x083FE8E8's call of the table lock 0x08404A38, with the
# fpscr read and the loads after it (r14 = the datagram, @(4,r15) = the sender's player number). The
# hook reads the CDJ-3000 extension (sounding key at 0x15C) that the 0x124-byte table copy drops.
STATUS_RX = dict(
    sig=[0x8B02, 0xD3C1, 0x432B, 0x0009, 0xD1C1, 0x410B, 0x0009, 0x096A, 0xD2C0, 0x51F1, 0xE449],
    start=4,
    end=10,
)

MODS = {
    'ks3k': Mod(
        what='KEY SYNC: the CDJ-3000 master\'s sounding key kept from its status packet (RAMB+0x1E800)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **STATUS_RX,
    ),
    # LINK0B (v4.2 DEV prototype, mods/link0b): the CDJ-3000 precise-position packet (0x0b, UDP 50001)
    'link0brx': Mod(
        what='LINK 0x0B: take a CDJ-3000 / Cueline 0x0b precise position (arrival-stamped, RAMB+0x1E600)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **BEAT_RECV,
    ),
    'link0btx': Mod(
        what='LINK 0x0B: send our 0x0b every 30 ms to CDJ-3000 / Cueline peers; publish the master 0x0b to the GUI',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DJCONT_PASS,
    ),
    # The detail-waveform builder's own PWV5 fetch, right after it returns:
    # r15+8/+12 still hold the &out_ptr/&out_size the fetch wrote into (read
    # again a few instructions later, once this call site resumes, to fill
    # the shared ctx's own RGB fields), r10 still holds the fetch's hash
    # argument, and the ANLZ handle this call opened is at r15+16 -- all of
    # it live only in this one span, which is why the hook sits exactly
    # here rather than earlier or later in the same function. r6/r7/r10 and
    # the bsr are reproduced first, so the RGB path is untouched whether or
    # not this mod's own fetches below succeed.
    'wave3data': Mod(
        what='3-band detail waveform data fetch (PWV7)',
        target='main',
        fw_versions=('1.87',),
        sig=[0x67F3, 0x66F3, 0x7708, 0x65A3, 0x760C, 0xDA18, 0xBC7B, 0x1FE5],
        start=0,
        end=8,
        args=[],
        literal=False,
    ),
    # Hooks DETAIL_CONVERTED: writes the words the wave3data mod packed into the
    # re-encoded waveform record, reading its buffer through two words at fixed
    # addresses (see main_wave3data.s).
    'wave3detail': Mod(
        what='3-band detail waveform data (PWV7 in the waveform record)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DETAIL_CONVERTED,
    ),
    # Hooks OVERVIEW_PUBLISH: writes the PWV6 bands the wave3ovfetch mod kept
    # into the overview payload, reading that mod's buffer through a word at a
    # fixed address (see main_wave3ovfetch.s).
    'wave3ovdata': Mod(
        what='3-band overview data (PWV6 in the overview payload)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **OVERVIEW_PUBLISH,
    ),
    # Hooks PREVIEW_READ: reads and packs the track's PWV6 for wave3ovdata.
    'wave3ovfetch': Mod(
        what='3-band overview data fetch (PWV6)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **PREVIEW_READ,
    ),
    # Hooks PREVIEW_READ: reads the track's PSSI and beat grid and reduces them
    # to the 600-column phrase table phrasedata writes.
    'phrasefetch': Mod(
        what='phrase analysis (PSSI) read and reduced to overview columns',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **PREVIEW_READ,
    ),
    # Hooks OVERVIEW_PUBLISH: writes the phrase table phrasefetch kept into the
    # overview records' spare bits (see main_phrasedata.s).
    'phrasedata': Mod(
        what='phrase colours in the overview payload',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **OVERVIEW_PUBLISH,
    ),
    'abletonlink': Mod(
        what='Ableton Link announcements (UDP 20808)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **BEAT_SEND,
    ),
    'abletonlinkpong': Mod(
        what='Ableton Link measurement replies (UDP 50000)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **LINK_RECEIVE,
    ),
    'osc': Mod(
        what='OSC deck state and load/play/stop/cue/loop events (UDP 50010)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **STATUS_SEND,
    ),
    'oscbeat': Mod(
        what='OSC per-beat output (UDP 50010)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **BEAT_SEND,
    ),
    'tcnet': Mod(
        what='TCNet Opt-IN and Status, once a second (UDP 60000)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **STATUS_SEND,
    ),
    'tcnettime': Mod(
        what='TCNet Time packets, every 20 ms (UDP 60001)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DJCONT_PASS,
    ),
    'linkcue': Mod(
        what='Link Cue prototype: stream a file of this deck or of a LINKed one over UDP 50099',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DJCONT_PASS,
    ),
    # Touch Audio (Link Cue) emitter: while TAG LIST is held the deck streams
    # its loaded track (fallback C:/lc48.wav) to the DJM-A9's LINK CUE as a
    # CDJ-3000 Touch Preview would. Two hooks share a block at 0x081FF800:
    # this one spawns the TchAud task (device-17 "CDJ-3000" keepalive, 50004
    # timing receive and 7 ms 0x1e audio send).
    # Waveform per browse row (mods/rowwave): every list row gets our own
    # 80x28 bitmap in place of its artwork thumbnail.
    'rowwave': Mod(
        what='Row waveform: a bitmap of ours on every browse row (after the list parser)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **LIST_PARSE_A,
    ),
    'rowwaveb': Mod(
        what='Row waveform: the same, after the parser\'s second call site',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **LIST_PARSE_B,
    ),
    # UTILITY: tint each settings-row label by the origin of its item (stock
    # white / ours green / any other violet). Classifies the item's label pointer
    # against the modsmenu block [FA_LO, FA_HI); UTILITY-only builder, so
    # browse/INFO are untouched. See mods/utiltint/main_utiltint.s.
    'utiltint': Mod(
        what='UTILITY: tint each settings-row label by origin (stock/ours/other)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **UTILITY_ROW,
    ),
    'touchaudio': Mod(
        what='Touch Audio (Link Cue) emitter: stream the loaded track to the mixer LINK CUE',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DJCONT_PASS,
    ),
    # Touch Preview: replaces the body of the overview strip's touch handler
    # (0x084EDC5A, zone 0 of the touch table) with the same column clamp and
    # needle search, skipped while the browser's INFO pop-up is open -- the
    # strip then belongs to the TchAud task's preview of the INFO track -- and
    # while Touch Cue owns it (UTILITY > LINK CUE includes CUE, a rekordbox
    # track playing); otherwise the stock needle search runs as before.
    'touchaudiotouch': Mod(
        what='Touch Audio: no needle search on the strip while INFO is open or Touch Cue (LINK CUE) plays',
        target='main',
        fw_versions=('1.87',),
        sig=[0x4F22, 0xD50F, 0xE701, 0x6152, 0x3418, 0x3473, 0x8D02, 0x6643,
             0xA006, 0xE601, 0xE202, 0x4218, 0x7258, 0x3627, 0x8B00, 0x6623,
             0xD210, 0xE501, 0x420B, 0xE400, 0x4F26, 0x000B, 0xE001],
        start=1,            # after `sts.l pr,@-r15`
        end=20,             # up to `lds.l @r15+,pr`
        args=[],
        literal=False,
    ),
    # The MAIN -> GUI frame packer skips the overview strip (and all else)
    # whenever the player model is dirty -- nearly every frame while a track
    # plays -- so the task's preview strip only showed once the deck paused.
    # Replaces the lock release after the dirty computation (0x0838EB7A, eight
    # words) with one that packs the strip first when ours is pending.
    'touchaudiopack': Mod(
        what='Touch Audio: the preview strip packed into a frame while the deck plays (model dirty)',
        target='main',
        fw_versions=('1.87',),
        sig=[0x476A, 0x016A, 0x54F1, 0x21E9, 0x4C0B, 0x416A, 0x026A, 0x84FC,
             0x6403, 0x22E9, 0xB454, 0x426A],
        start=1,            # sts fpscr,r1
        end=9,              # up to `mov r0,r4`; resumes at `and r14,r2`
        args=[],
        literal=False,
        hook=False,
    ),
    # Hooks LINK_RECEIVE: learns the A9's address from its 50000 keepalive, for
    # the task's device-17 keepalive / audio destination.
    'touchaudioip': Mod(
        what='Touch Audio: learn the mixer address from its keepalive (UDP 50000)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **LINK_RECEIVE,
    ),
    # 32-bit WAV playback (mods/wav32): the parser presents 32-bit integer or
    # float WAV as 24-bit PCM and the play path's file layer converts.
    'wav32fmt': Mod(
        what='32-bit WAV: fmt chunk presented as 24-bit PCM (int32/float32/EXTENSIBLE)',
        target='main',
        fw_versions=('1.87',),
        sig=[0x84C9, 0x660C, 0x84C8, 0x4618, 0x620C, 0x362C, 0x666D, 0x6063, 0x8801, 0x8901, 0xA104, 0x0009],
        start=0,
        end=8,
        args=[],
        literal=False,
        hook=False,
    ),
    'wav32data': Mod(
        what='32-bit WAV: data length scaled to the 24-bit stream, track recorded',
        target='main',
        fw_versions=('1.87',),
        sig=[0xE040, 0x1FB7, 0x0AFE, 0xE04C, 0x0FE6, 0xD153, 0x54F5, 0x6212, 0x3420, 0x8B26, 0x51F8, 0x52F6],
        start=0,
        end=8,
        args=[],
        literal=False,
        hook=False,
    ),
    'wav32fo': Mod(
        what='32-bit WAV: play file object keeps the real length; FILE marked',
        target='main',
        fw_versions=('1.87',),
        sig=[0x66F2, 0x5476, 0x1242, 0x6483, 0x5577, 0x1253, 0x55F1, 0xD32F, 0x430B, 0x1216],
        start=0,
        end=6,
        args=[],
        literal=False,
        hook=True,
    ),
    'wav32seek': Mod(
        what='32-bit WAV: seek offsets scaled 4/3 for a marked file',
        target='main',
        fw_versions=('1.87',),
        sig=[0x2FB6, 0x2FC6, 0x2FD6, 0x2FE6, 0x4F22, 0x7FFC, 0x6E6E, 0xE200, 0x2EE8, 0x1424],
        start=0,
        end=6,
        args=[],
        literal=False,
        hook=True,
    ),
    'wav32rd': Mod(
        what='32-bit WAV: read asks 4/3 bytes for a marked file',
        target='main',
        fw_versions=('1.87',),
        sig=[0x2FB6, 0x2FC6, 0x2FD6, 0x2FE6, 0x4F22, 0x7FF8, 0x2668, 0xE100, 0x1414, 0x6B73],
        start=0,
        end=6,
        args=[],
        literal=False,
        hook=True,
    ),
    'wav32rdend': Mod(
        what='32-bit WAV: 4-byte samples packed to 24-bit after the read',
        target='main',
        fw_versions=('1.87',),
        sig=[0x026A, 0xD10C, 0x6603, 0x1F62, 0x2219, 0x426A, 0x2668, 0x8F1D, 0x7F04, 0xDC09],
        start=0,
        end=6,
        args=[],
        literal=False,
        hook=True,
    ),
    'tcnetdata': Mod(
        what='TCNet listener (UDP 65023): Metrics and MetaData to requesting nodes',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **DJCONT_PASS,
    ),
    'usbmidi': Mod(
        what='USB-MIDI start/stop/clock, sending',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **MIDI_TASK,
    ),
    'usbmiditick': Mod(
        what='USB-MIDI start/stop/clock, 1 ms timing',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=True,
        **TIMER_TICK,
    ),
    # W8 (mods/w8fetch, opt-in): the TEMPO MASTER's PWV5 for the display's
    # phase meter -- fetched through the DB task, streamed as message 0x31.
    'w8send': Mod(
        what='W8: the tempo master\'s detail waveform (PWV5) and grid fetched and sent to the display (0x31)',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=False,
        **FRAME_PACK,
    ),
    'w8cap': Mod(
        what='W8: the DB task\'s replies to the w8send requests kept, not mailed',
        target='main',
        fw_versions=('1.87',),
        args=[],
        literal=False,
        hook=False,
        **DB_REPLY,
    ),
    # USB SOURCE KEY steady (mods/usbkey, opt-in): placed only (no call site);
    # place_usbkey() points the lamp pass's literal for the USB key's
    # predicate at it. See USBKEY_LIT below and re/USB_KEY_STEADY.md.
    'usbkey': Mod(
        what='USB SOURCE KEY lit while the USB is mounted (the PORT light keeps its stock blink)',
        target='main',
        fw_versions=('1.87',),
        sig=[],
        start=0,
        end=0,
        args=[],
        literal=False,
    ),
    # V4n19 TEST (opt-in): JOG ring colour probe, 20..52 s after boot (re/JOG_LED_RE.md); place_jogtest()
    'jogtest': Mod(
        what='JOG ring colour probe (A/B levels 0..3, 2 s each, 20-52 s after boot)',
        target='main',
        fw_versions=('1.87',),
        sig=[],
        start=0,
        end=0,
        args=[],
        literal=False,
    ),
    # opt-in: jog centre red marker blinks during the 2 s before the CUE point (re/JOG_CENTER_RE.md); place_jogcue()
    'jogcue': Mod(
        what='jog centre red marker (stock = CUE point) blinks 2 s before the cue',
        target='main',
        fw_versions=('1.87',),
        sig=[],
        start=0,
        end=0,
        args=[],
        literal=False,
    ),
    # V4 TEST builds (opt-in; re/AUTOTEST_USBLOG.md): scripted panel input from C:/V3TEST/SCRIPT.BIN
    # and the GUI HUD log to C:/V3HUD.BIN. Placed only: place_autotest() points the panel decoder's
    # two literals at autotest, place_testhooks() gives the TchAud loop (touchaudiot) both ticks.
    'autotest': Mod(
        what='TEST: autotest executor (panel decoder literals H1/H2) + C:/V3TEST/SCRIPT.BIN loader (TchAud)',
        target='main',
        fw_versions=('1.87',),
        sig=[],
        start=0,
        end=0,
        args=[],
        literal=False,
    ),
    'usblog': Mod(
        what='TEST: GUI HUD records (SPI frame +0x800) appended to C:/V3HUD.BIN while paused (TchAud)',
        target='main',
        fw_versions=('1.87',),
        sig=[],
        start=0,
        end=0,
        args=[],
        literal=False,
    ),
}
# V4n37 (opt-in): the BLACK BOX event recorder (mods/bbox, work/bbox/decode_bbox.py). Placed only: place_bbox()
# gives the TchAud loop (touchaudio / touchaudiot t_bbx) its entry.
MODS['bbox'] = MODS['usblog']._replace(
    what='BLACK BOX: a RAM ring of the last 512 deck events (TchAud), dumped to C:/BLACKBOX.BIN on MENU+BACK 3 s / errors')
MODS['wave3ovrgb'] = MODS['wave3ovdata']._replace(
    what='3-band overview data; CDJ-3000 RGB recolour of the stock overview without 3-band data')
# touch_audio with TESTHOOK (main_touchaudiot.s): taken instead of touchaudio when autotest / usblog
# is named (patch()); the default touchaudio blob is untouched.
MODS['touchaudiot'] = MODS['touchaudio']._replace(
    what='Touch Audio (Link Cue) emitter, TEST variant: the TchAud loop also runs the autotest / usblog ticks')


def source(name):
    """Each routine sits in its own mod's folder, mods/<mod>/."""
    return glob.glob(os.path.join(HERE, '*', 'main_%s.s' % name))[0]


def blob_path(name):
    return source(name)[:-2] + '.bin'


# Memory layouts: where our routines are placed (the sigpatch range), where
# the tadec blob is linked and where our run-time state lives (RAMB, a 128 KB
# block; see layout.inc). 'stock' is the stock firmware's code cave and what
# the committed .bin files are built for; 'ks' is the KEY SHIFT layout
# (below).
#   lang8       mods/lang8 (lang8.py): its 1 KB block, after modsmenu's block
#               and table (menu + 0x1400), below the tadec blob / RAMB.
LAYOUTS = {
    'stock': dict(code=(0x0811AF80, 0x08140000), tadec=0x08140000,
                  tadec_bin='tadec/main_tadec.bin', ramb=0x081E0000, menu=0x0813B000,
                  lang8=0x0813FF00),
    # V4k: KEY SHIFT (mods/keyshift): the Key Shift engine moves the DSP boot
    # table to 0x08130000-0x081C22C8 and keeps its SH-4 routine / state at 0x08122000 / 0x08122800
    # (our front end at 0x08123000), so ours go into the freed table 0x080034E0-0x08091234: the
    # routines 0x08003500-0x08014000 (68 KB), modsmenu + its table 0x08014000 (12 KB), lang2 at
    # 0x08017000, tadec relinked at 0x08018000 with a 256 KB arena (ends 0x08080190); RAMB stays.
    # V4n37h: lang2 moved up to 0x08017C00 (its block <= 0x100 B, tadec at 0x08018000): the UTILITY table had
    # reached 0x08016FDC (36 B under lang2), the menu block + table now have 0x08014000-0x08017C00 (15 KB).
    'ks': dict(code=(0x08003500, 0x08014000), tadec=0x08018000,
               tadec_bin='tadec/main_tadec_08018000.bin', ramb=0x081E0000, menu=0x08014000,
               lang8=0x08017C00),
}


def layout_for(names, layout=None):
    """The MAIN layout a mod set is built in: `ks` when keyshift is named."""
    if layout is None or layout == 'stock':
        return 'ks' if 'keyshift' in names else 'stock'
    return layout


# Prebuilt blobs placed at a FIXED address in the code cave (linked there,
# not position independent), above where sigpatch bump-places the mods:
# name -> (address, .bin relative to mods/, what). Built by their own
# build.sh; --assemble leaves them alone.
FIXED = {
    'tadec': (0x08140000, 'tadec/main_tadec.bin',
              'touch_audio: MP3/FLAC decoder blob (dr_mp3/dr_flac) at 0x08140000'),
    # V3h opt-in: the tadec blob with M4A (AAC-LC via FAAD2, ALAC via our C port of
    # Apple's decoder, our MP4 demuxer; mods/tadec/m4a/build.sh). Named together
    # with `tadec`, it takes its place (same address, same entry table) and lifts
    # touch_audio's file-type-4 gate (poke m4agate). Stock layout only.
    # tadecm4a = the -Os build (tadec/FLAC/ALAC -Os, dr_mp3 and FAAD2 -O2, SBR+PS): the
    # default since 2026-11-09 (MAIN flash); tadecm4ao2 = everything -O2 (+10 KB code).
    'tadecm4a': (0x08140000, 'tadec/main_tadec_m4a_Os.bin',
                 'touch_audio: MP3/FLAC/M4A decoder blob (FAAD2 AAC-LC/HE-AAC v1+v2, ALAC; -Os, MP3/FAAD2 -O2) at 0x08140000, replaces tadec'),
    'tadecm4ao2': (0x08140000, 'tadec/main_tadec_m4a.bin',
                   'touch_audio: tadecm4a built all -O2 (bigger MAIN section), replaces tadec'),
    # the "cap" variants (MAIN under the old 0x902A00 updater limit): the tadec blob built -Os
    # (mods/tadec/build.sh OPT=Os), named together with `tadec` it takes its place -- selected by
    # name, never by copying it over main_tadec.bin (2026-11-09: a copy/restore raced the tadec owner)
    'tadecos': (0x08140000, 'tadec/main_tadec_Os.bin',
                'touch_audio: MP3/FLAC decoder blob built -Os (cap builds) at 0x08140000, replaces tadec'),
    # placed by place_modsmenu(), not place_fixed(): linked per layout
    'modsmenu': (0x0813E000, 'modsmenu/modsmenu.s',
                 'UTILITY > MODS (saved) / LINK CUE / WAV 32-BIT: OFF/ON for our mods'),
    # V4k: placed by keyshift.apply() (Key Shift engine + our front end), not place_fixed(); selects the ks layout
    'keyshift': (0x08123000, 'keyshift/main_keyshift.s',
                 'KEY SHIFT: Key Shift engine (DSP pitch shifter) + our UTILITY / panel / rekordbox-key front end'),
    # ownks: named with keyshift, keyshift.apply() puts OUR engine (mods/ownks: DSP output pitch shifter +
    # MAIN sender) behind the same front end. Not placed by place_fixed().
    'ownks': (0x08122000, 'ownks/ownks.py',
              'KEY SHIFT engine: ours (DSP output pitch shifter, no third-party code); with keyshift'),
    # opt-in (re/MAIN_STOCK_RECLAIM.md #1): not a blob; reclaim.apply() erases the stock non-Latin
    # codepage tables + converters in place (every language -> cp1252) after every other mod.
    'reclaim': (0x08101B00, 'reclaim/reclaim.py',
                'reclaim: non-Latin text codepages dropped (every language -> cp1252), ~96 KB packed MAIN freed'),
}


# The UTILITY menu engine (re/UTILITY_ITEMS.md): its item table pointer in
# four literals, the item count in .data, the stock table in .data.
UT_TABLE_LITS = (0x084F08C8, 0x084F0BF0, 0x084F0DEC, 0x084F1050)
UT_STOCK_TABLE_RAM, UT_STOCK_TABLE_IMG = 0x10DE1634, 0x08570AB0
UT_COUNT_IMG = 0x08571014
UT_ENTRY = 60
MM_ITEMS = 4            # MODS, LINK CUE, WAV 32-BIT, LINK CUE DIAG
MM_ITEMS2 = 4           # LIGHT MODE, BPM DECIMALS, WAVEFORM COLOR, WAVEFORM CURRENT POSITION
                        # (modsmenu's entries2: saved in settings byte 7 bits 4-7 + byte 6 bits 0/4,
                        # free on stock; published to the display by mm_publish)
# The UTILITY order every build gets (labels as in the item table); items a
# build does not have are skipped, unknown ones go before VERSION No.
# V3e1: grouped as the CDJ-3000's UTILITY categories (re/V3E_DESIGN.md §5.1) -- DJ SETTING, DISPLAY (LCD),
# DISPLAY (INDICATOR), PRO DJ LINK, SYSTEM, INFO; the V2 display derives the category from the row's label.
UT_ORDER = (
    'PLAY MODE', 'EJECT/LOAD LOCK', 'QUANTIZE BEAT VALUE', 'HOT CUE AUTO LOAD',
    'HOT CUE COLOR', 'AUTO CUE LEVEL', 'GATE CUE', 'SEARCH BEAT JUMP', 'BEAT JUMP BUTTONS', 'KEY SHIFT',
    'REKORDBOX BUTTON', 'KEY SYNC BUTTON',
    'LANGUAGE', 'LCD BRIGHTNESS', 'TOUCH DISPLAY CALIBRATION', 'SCREEN SAVER',
    'LIGHT MODE', 'BPM DECIMALS', 'WAVEFORM COLOR', 'WAVEFORM CURRENT POSITION',
    'WAVEFORM',                         # HALFBLUE V4n41 (modsmenu wh_v: FULL / HALF overview + browse mini waves)
    'OVERVIEW WAVEFORM TYPE',
    'KEY FORMAT',                       # V4n36 (modsmenu kf_v: CLASSIC / ALPHANUMERIC, the 3000's key display format setting)
    'BEAT NUMBERS', 'GRID ADJUST',      # V4n27b (modsmenu bn_v / ga_v); v4.1: normal features (RELAUDIT)
    'SLIP FLASHING', 'ON AIR DISPLAY', 'JOG BRIGHTNESS', 'JOG INDICATOR', 'DISC SLOT ILLUMINATION',
    'PLAYER No.', 'LINK STATUS', 'MIDI CHANNEL', 'DUPLICATION', 'LINK CUE',
    'LINK OFFSET',                      # LINKLAT (v4.2) / LINKOFF: modsmenu lo_v, the LINK meter's lead (ms), OFF default
    'HISTORY NAME', 'DIGITAL OUT', 'AUTO STANDBY', 'MODS', 'WAV 32-BIT',
    'LINK CUE DIAG', 'TEST LOG', 'BUILD', 'VERSION No.',
)
# V4n36 trace: the kill switches (modsmenu entries5 + the LINK CUE item), after VERSION No. and counted out of the
# item count unless UTILITY TEST LOG is not OFF (modsmenu kl_reveal); each ON = the feature, OFF = its stock path
# 2.1.1: LINK CUE is NOT one of them any more -- it is a normal row in the PRO DJ LINK group (UT_ORDER, after
# DUPLICATION) in both profiles: with two Cueline decks it is the switch that turns Link Cue off on one of them
UT_KILL = ('LINK KEY STATUS', 'KEY SYNC', 'MASTER WAVE NFS', 'MASTER WAVEFORM', 'HW BAND LAYER',
           'LINK ROW PREVIEW', 'BLACK BOX',     # V4n37r: BLACK BOX = modsmenu kill_v+20 (row only with mods/bbox)
           'KS3 ENGINE',                        # KS3 (v4.1): kill_v+24, row only in CDJ_KSAB=1 DEV A/B test builds
           'LINK 0x0B')                         # LINK0B (v4.2): kill_v+28, row only with mods/link0b (CDJ_LINK0B=1)
# V4n36 trace: the build record (modsmenu bld_rec at the block + 0x180, kill_v at + 0x1E0; layout.inc BLDID / KILLB)
MM_BLD_OFF, MM_KILL_OFF = 0x180, 0x1E0
# V3e2: UT_ORDER's CDJ-3000 categories (re/V3E_DESIGN.md §5.1), for the UTILITY category taps
UT_CATS = (
    ('PLAY MODE', 'EJECT/LOAD LOCK', 'QUANTIZE BEAT VALUE', 'HOT CUE AUTO LOAD', 'HOT CUE COLOR', 'AUTO CUE LEVEL',
     'GATE CUE', 'SEARCH BEAT JUMP', 'BEAT JUMP BUTTONS', 'KEY SHIFT', 'REKORDBOX BUTTON',
     'KEY SYNC BUTTON'),
    ('LANGUAGE', 'LCD BRIGHTNESS', 'TOUCH DISPLAY CALIBRATION', 'SCREEN SAVER', 'LIGHT MODE', 'BPM DECIMALS',
     'WAVEFORM COLOR', 'WAVEFORM CURRENT POSITION', 'WAVEFORM', 'OVERVIEW WAVEFORM TYPE', 'KEY FORMAT', 'BEAT NUMBERS',
     'GRID ADJUST'),
    ('SLIP FLASHING', 'ON AIR DISPLAY', 'JOG BRIGHTNESS', 'JOG INDICATOR', 'DISC SLOT ILLUMINATION'),
    ('PLAYER No.', 'LINK STATUS', 'MIDI CHANNEL', 'DUPLICATION', 'LINK CUE', 'LINK OFFSET'),
    ('HISTORY NAME', 'DIGITAL OUT', 'AUTO STANDBY', 'MODS', 'WAV 32-BIT'),
    ('LINK CUE DIAG', 'TEST LOG', 'BUILD', 'VERSION No.'),
)
# V3e1 (video audit Q15): the LINK CUE DIAG row is a debug aid, not a user item -- left out of the
# table unless CDJ_UT_DIAG=1 (its text word stays in the block: the TchAud task still writes it)
UT_HIDE = () if os.environ.get('CDJ_UT_DIAG') == '1' else ('LINK CUE DIAG',)
# V4n18 (user 2026-11-13): MODS / LINK CUE / WAV 32-BIT are native (always on) on the CDJ-3000 -> hidden; each is
# ON / BOTH at every boot anyway (modsmenu), the NOMODS file stays the hidden kill switch
UT_HIDE = UT_HIDE + ('MODS', 'WAV 32-BIT', 'REKORDBOX BUTTON')   # V4n23: rekordbox button stock (user)
# 2.1.1 (owner): LINK CUE is visible again in BOTH profiles (it was hidden here and brought back only as a kill
# switch, i.e. only with TEST LOG on). LINK CUE DIAG and the kill switches stay hidden exactly as before.
MM_LOAD_LIT, MM_LOAD_STOCK = 0x0846D990, 0x083FC4DC      # QUANTIZE setter (unpack)
MM_SAVE_LIT, MM_SAVE_STOCK = 0x0846D5D0, 0x08401B60      # getter after byte 5 (pack)
# V3rc2: the packer's memset of the HISTORY-name record (type 3) -> hist_save (BEAT JUMP + WAVEFORM COLOR hi bit)
# R21 (2.01-b): hist_save also writes the versioned v1 settings block (modsmenu.s 'VERSIONED SETTINGS')
MM_HIST_LIT, MM_HIST_STOCK = 0x0846D5D4, 0x08533D50
MM_COPY_LITS, MM_COPY_STOCK = (0x08390944, 0x08391B60), 0x085336DC  # heartbeat block copies
# V3e2: the panel task's touch_event calls (re/V3E_DESIGN.md §1.3) -> modsmenu v3e_touch (the CDJ-3000 tap targets)
MM_TOUCH_LITS, MM_TOUCH_STOCK = (0x0844E240, 0x0844E488), 0x084ECCF8
# V3rc1: the UI task's knob poll calls the delta / accumulator 0x084D2210 through this literal
MM_KNOB_LIT, MM_KNOB_STOCK = 0x0844F1C8, 0x084D2210


def build_modsmenu(base, layout='stock'):
    """(bytes, {symbol: address}) of mods/modsmenu linked at base."""
    src = os.path.join(HERE, 'modsmenu', 'modsmenu.s')
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (os.path.join(tmp, n) for n in ('m.o', 'm.elf', 'm.bin'))
        ramb = [l['ramb'] for l in LAYOUTS.values() if l['menu'] == base]
        v3e2 = ['--defsym', 'V3E2=1'] if os.environ.get('CDJ_V3E2', '1') == '1' else []   # V3e2 touch layer + publish
        if layout == 'ks':          # V4k: the KEY SHIFT items, touch zones and publish (mods/keyshift)
            v3e2 += ['--defsym', 'KEYSHIFT=1', '--defsym', 'KSB=0x08123000']
            if os.environ.get('CDJ_TESTLOG') == '1':    # V4n: UTILITY TEST LOG (TEST builds, set by place_modsmenu)
                v3e2 += ['--defsym', 'TESTLOG=1']
            if os.environ.get('CDJ_BBOX') == '1':       # V4n37r: the BLACK BOX kill-switch row (mods/bbox in, patch())
                v3e2 += ['--defsym', 'BBOX=1']
            if os.environ.get('CDJ_LINK0B') == '1':     # LINK0B (v4.2): the LINK 0x0B kill-switch row (mods/link0b in)
                v3e2 += ['--defsym', 'LINK0B=1']
            if os.environ.get('CDJ_KSAB') == '1' and os.environ.get('CDJ_TESTLOG') == '1':   # KS3: A/B row (DEV + ownks)
                v3e2 += ['--defsym', 'KSAB=1']
        subprocess.run(['sh4-linux-gnu-as', '--isa=sh4', '-little', '--defsym', 'RAMB=%#x' % ramb[0]] + v3e2 +
                       ['-I', os.path.join(HERE, 'v2ui'),     # TOUCH (V4n41): vt_zones = v2ui/touch_vt_zones.inc
                        '-o', obj, src], check=True)
        subprocess.run(['sh4-linux-gnu-ld', '-Ttext=%#x' % base, '-e', 'entry', '-o', elf, obj], check=True)
        subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary', '-j', '.text', elf, out], check=True)
        syms = {}
        for line in subprocess.run(['sh4-linux-gnu-nm', elf], check=True, capture_output=True,
                                   text=True).stdout.splitlines():
            f = line.split()
            if len(f) == 3:
                syms[f[2]] = int(f[0], 16)
        with open(out, 'rb') as f:
            return f.read(), syms


def place_modsmenu(data, layout='stock'):
    """The UTILITY item "MODS" (mods/modsmenu): its block at the layout's
    menu address, its entry appended to the item table (a copy of the stock
    table after the block, or the end of a base's own table) with the count
    bumped, and the settings unpacker/packer literals redirected."""
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    u32 = lambda a: struct.unpack_from('<I', out, o(a))[0]
    base = LAYOUTS[layout]['menu']
    blob, syms = build_modsmenu(base, layout)
    assert (syms['mods_off'], syms['lc_off'], syms['w32_off'], syms['diag_txt']) == \
        (base + 240, base + 244, base + 248, base + 256), \
        'the item words must sit at the block base + 240/244/248, the diagnostic text at ' \
        '+256 (layout.inc MODSV/LCV/W32V/DIAGT)'
    if 'bld_rec' in syms:       # V4n36 trace: build record + kill switches at fixed offsets (layout.inc BLDID / KILLB)
        assert (syms['bld_rec'], syms['kill_v']) == (base + MM_BLD_OFF, base + MM_KILL_OFF), \
            'modsmenu: bld_rec / kill_v must sit at the block base + %#x / %#x' % (MM_BLD_OFF, MM_KILL_OFF)
        blob = fill_build_record(blob, base, syms)
    e2 = syms['entries2'] - base
    entry = blob[:UT_ENTRY * MM_ITEMS] + blob[e2:e2 + UT_ENTRY * MM_ITEMS2]
    if 'entries3' in syms:      # V4k: KEY SHIFT, REKORDBOX BUTTON; V4n24: KEY SYNC BUTTON
        e3 = syms['entries3'] - base
        entry += blob[e3:e3 + UT_ENTRY * (3 + 2 * ('L_BN' in syms) + ('L_KF' in syms) + ('L_TL' in syms))]   # V4n27b: + BEAT NUMBERS, GRID ADJUST; V4n36 KEY FORMAT
    if 'entries4' in syms:      # V4n36 trace: BUILD (read-only), then the kill switches (entries5 .. entries5_end)
        e4, e5 = syms['entries4'] - base, syms['entries5_end'] - base
        assert (e5 - e4) % UT_ENTRY == 0
        entry += blob[e4:e5]
    count = out[o(UT_COUNT_IMG)]
    table = u32(UT_TABLE_LITS[0])
    if any(u32(a) != table for a in UT_TABLE_LITS):
        raise SystemExit('patch_main: modsmenu: the UTILITY table literals disagree')
    # the build's items as they are (the stock .data table, or the table
    # the image's literals point at), plus ours, into our own table in UT_ORDER
    src = UT_STOCK_TABLE_IMG if table == UT_STOCK_TABLE_RAM else table
    items = [bytes(out[o(src) + k * UT_ENTRY:o(src) + (k + 1) * UT_ENTRY]) for k in range(count)]
    items += [entry[k * UT_ENTRY:(k + 1) * UT_ENTRY] for k in range(len(entry) // UT_ENTRY)]

    def label(e):
        a = (struct.unpack_from('<I', e, 0)[0] & 0x1FFFFFFF) | 0x08000000
        if base <= a < base + len(blob):
            return blob[a - base:a - base + 96].decode('utf-16-le', 'replace').split('\0')[0]
        raw = bytes(out[o(a):o(a) + 96])
        return raw.decode('utf-16-le', 'replace').split('\0')[0]
    names = [label(e) for e in items]
    kills = UT_KILL if 'entries5' in syms else ()    # V4n36 trace: LINK CUE comes back as a kill switch
    keep = [k for k, n in enumerate(names) if n not in UT_HIDE or n in kills]
    items, names = [items[k] for k in keep], [names[k] for k in keep]
    rank = {n: k for k, n in enumerate(UT_ORDER)}
    last = rank['VERSION No.']
    rank.update({n: last + 1 + k for k, n in enumerate(kills)})     # after VERSION No.
    order = sorted(range(len(items)), key=lambda k: (rank.get(names[k], last - 0.5), k))
    nkill = sum(1 for n in names if n in kills)
    tab = b''.join(items[k] for k in order)
    new_table = (base + len(blob) + 15) & ~15
    span = (base, new_table + len(tab))
    if any(b != 0xFF for b in out[o(span[0]):o(span[1])]):
        raise SystemExit('patch_main: modsmenu: %#x-%#x is not free' % span)
    out[o(base):o(base) + len(blob)] = blob
    out[o(new_table):o(new_table) + len(tab)] = tab
    if 'vt_ucat' in syms:   # V3e2: UTILITY category tiles -> the first item of each category (v3e_touch)
        firsts = []
        for group in UT_CATS:
            pos = [i for i, k in enumerate(order) if names[k] in group]
            firsts.append(pos[0] if pos else 0)
        out[o(syms['vt_ucat']):o(syms['vt_ucat']) + 6] = bytes(firsts)
    if 'vt_ute' in syms:    # V3e2: the SHORT CUT LCD / JOG BRIGHTNESS tiles step these two items (v3e_touch)
        for j, want in enumerate(('LCD BRIGHTNESS', 'JOG BRIGHTNESS', 'PLAYER No.')):
            pos = [i for i, k in enumerate(order) if names[k] == want]
            if pos:
                struct.pack_into('<I', out, o(syms['vt_ute']) + 4 * j, new_table + UT_ENTRY * pos[0])
    if 'vt_utt' in syms:    # TOUCH (V4n41): UTILITY's item table for the option taps (modsmenu vu_opt)
        struct.pack_into('<I', out, o(syms['vt_utt']), new_table)
    if 'vt_bjl' in syms:    # V3e3: the player's < / > beat-jump tiles (zones 5 / 6) jump bj_v beats
        zones = ((5, 0x084EE318, 'vt_bjl'), (6, 0x084EE372, 'vt_bjr'))
        # the beat-jump request codes stop at 9 (16 beats) in the consumer and in the per-touch clear:
        # 13 (64 beats), re_deck (only from the stock values: other bytes are left alone)
        caps = ((0x08441516, (0x09,), 0x0D), (0x084ED740, (0x0A,), 0x0E))
        if all(u32(0x081010A0 + 20 * z + 16) == st for z, st, _ in zones) and \
                all(out[o(a)] in olds for a, olds, _ in caps):
            for z, st, sym in zones:
                struct.pack_into('<I', out, o(0x081010A0 + 20 * z + 16), syms[sym])
            for a, olds, nb in caps:
                out[o(a)] = nb
        else:
            print('patch_main: modsmenu: beat-jump tiles left stock (this base changed their handlers / caps)')
    for a in UT_TABLE_LITS:
        struct.pack_into('<I', out, o(a), new_table)
    # V4n36 trace: the kill switches are the table's last nkill items; the image's count leaves them out
    # (hidden), modsmenu kl_reveal raises it to all of them while TEST LOG is not OFF (normal boot only)
    out[o(UT_COUNT_IMG)] = len(items) - nkill
    if 'ut_n' in syms:
        struct.pack_into('<II', out, o(syms['ut_n']), len(items), nkill)
    for lit, stock, sym in ((MM_LOAD_LIT, MM_LOAD_STOCK, 'mods_load'),
                            (MM_SAVE_LIT, MM_SAVE_STOCK, 'mods_save')):
        if u32(lit) != stock:
            raise SystemExit('patch_main: modsmenu: literal %#x holds %#x, not %#x' % (lit, u32(lit), stock))
        struct.pack_into('<I', out, o(lit), syms[sym])
    if 'hist_save' in syms:
        if u32(MM_HIST_LIT) != MM_HIST_STOCK:
            print('patch_main: modsmenu: HISTORY-tail store not installed: literal %#x holds %#x (BEAT JUMP / BLUE '
                  'not saved)' % (MM_HIST_LIT, u32(MM_HIST_LIT)))
        else:
            struct.pack_into('<I', out, o(MM_HIST_LIT), syms['hist_save'])
    # LIGHT MODE / BPM DECIMALS reach the display in heartbeat word +0x54, set right before each
    # copy of the block (the deck rebuilds it between frames)
    for lit in MM_COPY_LITS:
        if u32(lit) != MM_COPY_STOCK:
            raise SystemExit('patch_main: modsmenu: heartbeat copy literal %#x holds %#x, not %#x'
                             % (lit, u32(lit), MM_COPY_STOCK))
        struct.pack_into('<I', out, o(lit), syms['mm_copy'])
    if 'v3e_touch' in syms:
        prev = {u32(lit) for lit in MM_TOUCH_LITS}
        if len(prev) != 1:
            raise SystemExit('patch_main: modsmenu: the touch_event literals disagree: %s' % sorted(map(hex, prev)))
        prev = prev.pop()
        if prev != MM_TOUCH_STOCK:   # V3e3: an image that already hooks touch_event: its bytes stay
            print('patch_main: modsmenu: touch layer (v3e_touch) not installed: the base hooks touch_event '
                  'itself (%#x)' % prev)
        else:
            for lit in MM_TOUCH_LITS:
                struct.pack_into('<I', out, o(lit), syms['v3e_touch'])
            # V3rc1: the UI task's knob poll -> vt_khook (a fast turn on a list = the 3000's letter jump)
            if 'vt_khook' in syms:
                if u32(MM_KNOB_LIT) != MM_KNOB_STOCK:
                    print('patch_main: modsmenu: letter jump not installed: the knob poll literal %#x holds %#x'
                          % (MM_KNOB_LIT, u32(MM_KNOB_LIT)))
                else:
                    struct.pack_into('<I', out, o(MM_KNOB_LIT), syms['vt_khook'])
    print('patch_main: UTILITY > MODS, LIGHT MODE, BPM DECIMALS, LINK CUE, WAV 32-BIT, LINK CUE DIAG at %#x; %d items in order at %#x: %s'
          % (base, len(items), new_table, ' | '.join(names[k] for k in order)))
    if 'bld_rec' in syms:
        print('patch_main: build record at %#x: %r; kill switches at %#x (%d items, %s)'
              % (syms['bld_rec'], build_id(), syms['kill_v'], nkill,
                 'shown while TEST LOG is on' if 'L_TL' in syms else 'always shown after boot (no TEST LOG)'))
    return bytes(out)


def build_id():
    """V4n36 trace: the build ID build_final.sh exports (CDJ_BUILD_ID = "TAG YYYYMMDD-HHMM HASH8", HASH8 = a
    git-less hash of the mods sources); 'dev <hash8>' otherwise. ASCII, <= 43 characters."""
    bid = os.environ.get('CDJ_BUILD_ID', '').strip()
    if not bid:
        bid = 'dev ' + source_hash()
    return bid.encode('ascii', 'replace')[:43].decode('ascii')


def source_hash():
    """8 hex digits of sha256 over every mods/ source (path + content, sorted; no caches / backups / blobs)."""
    import hashlib
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(HERE)):
        dirs[:] = sorted(d for d in dirs if d != '__pycache__')
        for f in sorted(files):
            if f.endswith(('.s', '.S', '.c', '.h', '.inc', '.py', '.ld', '.sh', '.conf')):
                pth = os.path.join(root, f)
                h.update(os.path.relpath(pth, HERE).encode() + b'\0' + open(pth, 'rb').read())
    return h.hexdigest()[:8]


def fill_build_record(blob, base, syms):
    """modsmenu's bld_rec: 'BLD1' + the ASCII build ID (44 bytes, NUL-padded), then bld_u16 = the UTILITY BUILD
    value "TAG HASH8" in UTF-16 (<= 23 characters + NUL, 48 bytes)."""
    out = bytearray(blob)
    bid = build_id()
    f = bid.split()
    shown = (f[0] + ' ' + f[-1]) if len(f) >= 2 else bid
    r = syms['bld_rec'] - base
    out[r:r + 48] = (b'BLD1' + bid.encode('ascii')).ljust(48, b'\0')
    u = syms['bld_u16'] - base
    assert u == r + 48
    out[u:u + 48] = shown[:23].encode('utf-16-le').ljust(48, b'\0')
    return bytes(out)


def place_fixed(data, names, layout='stock'):
    out = bytearray(data)
    lay = LAYOUTS[layout]
    m4a = [n for n in names if n in TADEC_M4A or n == 'tadecos']
    if len(m4a) > 1:
        raise SystemExit('patch_main: name only one of %s' % ', '.join(TADEC_M4A + ('tadecos',)))
    if m4a and layout != 'stock':
        raise SystemExit('patch_main: %s is built for the stock layout only (0x08140000)' % m4a[0])
    for name in names:
        if name == 'tadec' and m4a:
            continue                       # the M4A / -Os blob takes its place
        addr, rel, what = FIXED[name]
        if name == 'tadec':
            addr, rel = lay['tadec'], lay['tadec_bin']
            what = 'touch_audio: MP3/FLAC decoder blob (dr_mp3/dr_flac) at %#x' % addr
        with open(os.path.join(HERE, rel), 'rb') as f:
            blob = f.read()
        off = addr - 0x08000000
        if layout == 'stock':
            lo, hi = MAIN_PROFILE.ram_base, MAIN_PROFILE.ram_end
        else:
            lo, hi = lay['code'][1], lay['ramb']
        if not (lo <= addr and addr + len(blob) <= hi):
            raise SystemExit('patch_main: %s (%d bytes) does not fit %#x-%#x'
                             % (what, len(blob), lo, hi))
        if len(out) < off + len(blob):
            out += b'\xff' * (off + len(blob) - len(out))
        if any(b != 0xFF for b in out[off:off + len(blob)]):
            raise SystemExit('patch_main: %s: cave at %#x is not free' % (what, addr))
        out[off:off + len(blob)] = blob
        print('patch_main: %s, %d bytes at %#x' % (what, len(blob), addr))
    return bytes(out)


def check_free(data, lo, hi, what):
    """Erased (0xFF) image bytes, i.e. nothing of the base lives there."""
    seg = data[lo - 0x08000000:hi - 0x08000000]
    if len(seg) < hi - lo or any(b != 0xFF for b in seg):
        raise SystemExit('patch_main: %s %#x-%#x is not free in this image' % (what, lo, hi))


# In-place byte pokes, located by a unique byte pattern (position-independent:
# the instructions are reg/struct-offset and PC-relative branches, so the bytes
# are identical across builds/layouts). Applied after the code mods.
# rowgraypack: the browse-row packer FUN_0838EEE0 sends a grey-disc CLEAR for a
# row whose MODEL has_art (T+0x1C) != 1. The firmware clears has_art on the
# currently-loaded row, so our colour row went grey. Gate on the small bitmap
# pointer T+0x20 instead (our rows keep it into RAMB even when has_art is
# cleared; stock art-less rows have it 0, so they still get the grey disc; in
# stock has_art==1 <=> ptr!=0, so this is a no-op there). 3 halfwords, in place:
#   0x50E7 mov.l @(0x1c,r14),r0  -> 0x50E8 mov.l @(0x20,r14),r0
#   0x8801 cmp/eq #1,r0          -> 0x2008 tst r0,r0
#   0x8B37 bf <clear>            -> 0x8937 bt <clear>
MAIN_POKES = {
    # m4agate (rides with tadecm4a/tadecm4ao2): touch_audio's ow_codec refuses an
    # export row of file type 4 (M4A) before calling tadec_open (dr_mp3 would scan
    # the whole file for a sync). With the M4A blob tadec_open recognises 'ftyp'
    # itself, so the compare becomes cmp/eq #-1,r0 (the type is a zero-extended
    # byte: never equal). Pattern: mov.l oc_med,r2 / mov.l @(24,r2),r0 /
    # cmp/eq #4,r0 / bt ow_out.
    'm4agate': dict(
        what='touch_audio: M4A rows reach tadec_open (file-type-4 gate lifted)',
        find=bytes([0x21, 0xD2, 0x26, 0x50, 0x04, 0x88, 0x4C, 0x89]),
        repl=bytes([0x21, 0xD2, 0x26, 0x50, 0xFF, 0x88, 0x4C, 0x89]),
    ),
    # rgbdetail (V4m3, rides with three_band's wave3detail): the detail-waveform task 0x0849EB42 asks
    # for the RGB (PWV5) detail first only when stock's WAVEFORM COLOR for that medium is RGB (getter
    # 0x084031C8 = the media record's byte +0xA6, 1 BLUE / 3 RGB; rewritten at every load -- the emu with
    # stick7 has 3 although the stick's parsed DEVSETTING (0x0B512FF4) holds 1s, so the source is the deck's
    # own setting [G]); BLUE = the blue detail (PWV3, GUI type 0x36) only, and the band stayed blue in every
    # colour of OUR WAVEFORM COLOR (deck6 log; emu: getter forced to 1 reproduces it on V4m2).
    # cmp/eq #3,r0 -> sett: the mode word (0x0B531E9C) is always
    # 1 = RGB first; stock's own fallback (RGB fetched without data -> the blue detail, 0x0849F878) stays.
    'rgbdetail': dict(
        what='detail waveform: RGB (PWV5) requested first whatever the stick\'s WAVEFORM COLOR',
        find=bytes([0x0C, 0x60, 0x03, 0x88, 0xC9, 0x26, 0x6A, 0x46, 0x29, 0x05, 0x6F, 0xD7]),
        repl=bytes([0x0C, 0x60, 0x18, 0x00, 0xC9, 0x26, 0x6A, 0x46, 0x29, 0x05, 0x6F, 0xD7]),
    ),
    'rowgraypack': dict(
        what='browse row: loaded row keeps its colour (pack by bitmap ptr, not has_art)',
        find=bytes([0xE7, 0x50, 0x01, 0x88, 0x37, 0x8B]),
        repl=bytes([0xE8, 0x50, 0x08, 0x20, 0x37, 0x89]),
    ),
}


def apply_main_pokes(data, names):
    """Auto-applied in-place pokes. rowgraypack rides with rowwave."""
    data = bytearray(data)
    want = set()
    if 'rowwave' in names or 'rowwaveb' in names:
        want.add('rowgraypack')
    if 'wave3detail' in names:
        want.add('rgbdetail')
    if any(n in names for n in TADEC_M4A):
        if 'touchaudio' not in names:
            raise SystemExit('patch_main: tadecm4a needs touch_audio (its codec gate)')
        want.add('m4agate')
    for name in want:
        p = MAIN_POKES[name]
        i = data.find(p['find'])
        if i < 0 or data.find(p['find'], i + 1) >= 0:
            raise SystemExit('patch_main: poke %s pattern not found/unique' % name)
        data[i:i + len(p['repl'])] = p['repl']
        print('patch_main: poke %s at %#x (%s)' % (name, i, p['what']))
    return bytes(data)


TADEC_M4A = ('tadecm4a', 'tadecm4ao2')


# Mods kept out of sigpatch's shared segment unless named (it sizes the
# segment for every routine it is given; a new routine would move every
# existing build's bytes).
OPT_IN = ('ks3k', 'link0brx', 'link0btx', 'wave3ovrgb', 'w8send', 'w8cap', 'usbkey', 'jogtest', 'jogcue', 'autotest', 'usblog', 'touchaudiot', 'bbox')

# V4n37r build profiles (CDJ_PROFILE, set by work/v4n/build_final.sh PROFILE=): 'dev' (default) = everything;
# 'release' = the same features without the dev tooling. A release build may not name these (the network
# commander UDP 50098 + RED log UDP 50099 + C:/V3HUD.BIN = usblog, SCRIPT.BIN runner = autotest, TchAud test hooks =
# touchaudiot, the JOG probe = jogtest); without usblog modsmenu has no UTILITY TEST LOG (no TESTLOG) and shows the
# kill switches always, and the non-stock layouts assemble with RELEASE=1 (bbox: no 'V3BB' network stream).
PROFILES = ('dev', 'release')
# V4n41 (user, public release): no BLACK BOX either -- bbox (its RAM recorder, the MENU+BACK C:/BLACKBOX.BIN dump and
# its UTILITY row) is DEV-only now; a release image has no recorder, no log and no commander
DEV_ONLY = ('autotest', 'usblog', 'touchaudiot', 'jogtest', 'bbox')


def build_profile():
    p = os.environ.get('CDJ_PROFILE', 'dev') or 'dev'
    if p not in PROFILES:
        raise SystemExit('patch_main: CDJ_PROFILE=%s: not one of %s' % (p, ', '.join(PROFILES)))
    return p

# usbkey: the lamp pass 0x084DC768 sets the USB source key (0x0B54C030[2])
# from the predicate 0x084DC522 (USB PORT indicator in its ON phase) at
# 0x084DCA62 and 0x084DCADA, both through this one literal (no other reader).
USBKEY_LIT, USBKEY_STOCK = 0x084DCBE8, 0x084DC522
USBKEY_READERS = ((0x084DCA62, 0xD461), (0x084DCADA, 0xD643))
# NAVART: lamp pass, another player's medium slot 2 / slot 3: `tst #2,r0; bt` (skip [3] = 3 when flags & 2 == 0)
LINKKEY_BT = (0x084DC9DE, 0x084DCA04)


JOG_LITS = ((0x0844FA40, 0x084DC640), (0x0844FA44, 0x084DC64A))   # jogtest: ring A / B getter literals


def place_jogtest(data, addr):
    out = bytearray(data)
    for k, (lit, stock) in enumerate(JOG_LITS):
        if struct.unpack_from('<I', out, lit - 0x08000000)[0] != stock:
            raise SystemExit('patch_main: jogtest: literal %#x is not stock' % lit)
        struct.pack_into('<I', out, lit - 0x08000000, addr + 4 * k)
    print('patch_main: jogtest: ring getters -> %#x / %#x' % (addr, addr + 4))
    return bytes(out)


JOGCUE_LIT, JOGCUE_STOCK = 0x08450414, 0x0843E344   # jogcue: literal read by jsr @r6 at 0x0845038E


def place_jogcue(data, addr):
    out = bytearray(data)
    if struct.unpack_from('<I', out, JOGCUE_LIT - 0x08000000)[0] != JOGCUE_STOCK:
        raise SystemExit('patch_main: jogcue: literal %#x is not stock' % JOGCUE_LIT)
    struct.pack_into('<I', out, JOGCUE_LIT - 0x08000000, addr)
    print('patch_main: jogcue: hook literal -> %#x' % addr)
    return bytes(out)


def place_usbkey(data, addr):
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    if struct.unpack_from('<I', out, o(USBKEY_LIT))[0] != USBKEY_STOCK or \
            any(struct.unpack_from('<H', out, o(a))[0] != op for a, op in USBKEY_READERS):
        raise SystemExit('patch_main: usbkey: lamp-pass literal %#x / its readers are not stock' % USBKEY_LIT)
    struct.pack_into('<I', out, o(USBKEY_LIT), addr)
    print('patch_main: usbkey: USB key predicate literal %#x -> %#x' % (USBKEY_LIT, addr))
    # NAVART (user, V4n39 deck: the LINK key blinks with a LINK medium in use): the lamp pass lights the LINK key
    # [3] for another player's USB / SD only while its media flags (0x0A371DA6 / 7 + 292 x player) have BOTH 0x04
    # (present) and 0x02 -- 0x02 toggles (emu, 2 decks, LINK track loaded: the panel getter at 0x0844FB08 read
    # [3] = 1 / 3 alternately, 19-22 changes / 8 s). The `bt` that skips the lit store on 0x02 clear becomes a nop
    # (as usbkey: steady while the medium is there; 0x04 clear keeps the stock blink path)
    for a in LINKKEY_BT:
        if struct.unpack_from('<H', out, o(a))[0] != 0x8902:
            raise SystemExit('patch_main: usbkey: LINK key branch %#x is not stock (bt +2)' % a)
        struct.pack_into('<H', out, o(a), 0x0009)
    print('patch_main: usbkey: LINK key steady (nop at %s)' % ', '.join('%#x' % a for a in LINKKEY_BT))
    return bytes(out)


# autotest (re/AUTOTEST_DESIGN.md §2): H1 = the panel decoder's "debug key active?" call
# (0x0844D408 reads the literal once, at 0x0844D414) -> autotest +0; H2 = its touch calibration
# call (literal read once, at 0x0844E188, into r12) -> autotest +4. Both literals have no other reader.
AT_LITS = ((0x0844D730, 0x08201310, 0x0844D414, 0xD1C6, 0),
           (0x0844E23C, 0x084C37E4, 0x0844E188, 0xDC2C, 4))
# touchaudiot's test_hooks words (main_touchaudio.s, TESTHOOK): autotest +8, usblog +0, autotest +12
TESTHOOK_MARKS = (0x7E57A700, 0x7E57A701, 0x7E57A702, 0x7E57A703)
TESTHOOK_NAMES = ('autotest', 'usblog')


def place_autotest(data, addr):
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    for lit, stock, reader, op, entry in AT_LITS:
        if struct.unpack_from('<I', out, o(lit))[0] != stock or struct.unpack_from('<H', out, o(reader))[0] != op:
            raise SystemExit('patch_main: autotest: panel decoder literal %#x / its reader are not stock' % lit)
        struct.pack_into('<I', out, o(lit), addr + entry)
        print('patch_main: autotest: literal %#x (%#x) -> %#x' % (lit, stock, addr + entry))
    return bytes(out)


def place_testhooks(data, placed, blob_path):
    """The three test_hooks words of the placed touchaudiot: the autotest / usblog entries (0 when
    that mod is not in the build)."""
    out = bytearray(data)
    base = placed['touchaudiot']
    with open(blob_path('touchaudiot'), 'rb') as f:
        size = len(f.read())
    at = placed.get('autotest')
    ksb = 0x08123000            # V4n: UTILITY TEST LOG word = mods/keyshift KSB+68 (keyshift applied first)
    tl = ksb + 68 if out[ksb + 44 - 0x08000000:ksb + 48 - 0x08000000] == b'TFSK' else 0
    vals = (at + 8 if at else 0, placed.get('usblog', 0), at + 12 if at else 0, tl)
    lo, hi = base - 0x08000000, base - 0x08000000 + size
    for mark, val in zip(TESTHOOK_MARKS, vals):
        i = out.find(struct.pack('<I', mark), lo, hi)
        if i < 0 or out.find(struct.pack('<I', mark), i + 1, hi) >= 0 or i % 4:
            raise SystemExit('patch_main: touchaudiot: test_hooks word %#x not found once' % mark)
        struct.pack_into('<I', out, i, val)
    print('patch_main: touchaudiot: TchAud test hooks at %#x: autotest %#x, usblog %#x' % (base, vals[0], vals[1]))
    return bytes(out)


def _test_names(names):
    """autotest / usblog ride on the TchAud task: touchaudio is swapped for its TESTHOOK variant."""
    if not any(n in names for n in TESTHOOK_NAMES):
        return list(names)
    if 'touchaudio' not in names:
        raise SystemExit('patch_main: autotest / usblog need touchaudio (they run in its TchAud task)')
    return ['touchaudiot' if n == 'touchaudio' else n for n in names if n != 'touchaudiot']


# D4 (re/ARTWORK_DECODER.md §4): row artwork through the stock JPU/VEU path. JpegMgrTask's loop releases every message
# whose pool word is 0 through the literal at 0x083D6CF8 (free 0x08344B42; no other reader): touch_audio's jm_shim
# (behind the marker word) takes it, handles our own decode message and forwards everything else to free.
ARTJ_LIT, ARTJ_STOCK, ARTJ_MARK = 0x083D6CF8, 0x08344B42, 0x7E57A7D4


def place_artj(data, placed, blob_path):
    name = 'touchaudiot' if 'touchaudiot' in placed else 'touchaudio'
    if name not in placed:
        return data
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    if struct.unpack_from('<I', out, o(ARTJ_LIT))[0] != ARTJ_STOCK:
        raise SystemExit('patch_main: artj: JpegMgrTask free literal %#x is not stock' % ARTJ_LIT)
    with open(blob_path(name), 'rb') as f:
        blob = f.read()
    mk = struct.pack('<I', ARTJ_MARK)
    i = blob.find(mk)
    if i < 0 or blob.find(mk, i + 1) >= 0 or i % 4:
        raise SystemExit('patch_main: artj: jm_shim marker not found once in %s' % name)
    addr = placed[name] + i + 4
    struct.pack_into('<I', out, o(ARTJ_LIT), addr)
    print('patch_main: artj: JpegMgrTask free literal %#x -> jm_shim %#x' % (ARTJ_LIT, addr))
    return bytes(out)


# V4n36 trace (#51): MAIN gui_comm clears each RX slot (memset, literal 0x0838EAEC: its two calls 0x0838E9F6 /
# 0x0838EA12) right after parsing it, so usblog's 250-ms poll rarely saw the GUI's HUD block on the deck (whole
# boots with none). The literal -> usblog + 16 (hg_hook: the newest record copied out, then memset).
HUDGRAB_LIT, HUDGRAB_STOCK = 0x0838EAEC, 0x08533D50


def place_hudgrab(data, addr):
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    if struct.unpack_from('<I', out, o(HUDGRAB_LIT))[0] != HUDGRAB_STOCK:
        raise SystemExit('patch_main: usblog: gui_comm memset literal %#x is not stock' % HUDGRAB_LIT)
    struct.pack_into('<I', out, o(HUDGRAB_LIT), addr + 16)
    print('patch_main: usblog: gui_comm RX-clear literal %#x -> hg_hook %#x' % (HUDGRAB_LIT, addr + 16))
    return bytes(out)


BBOX_MARK, BBOX_KSB = 0x7E57A7B0, 0x08123000


def place_bbox(data, placed, blob_path):
    """V4n37 bbox: the TchAud loop's t_bbx word (after the marker in touchaudio / touchaudiot) -> the bbox entry;
    bbox +16 = KSB when mods/keyshift is in (its 'KSFT' magic), +12 = the UTILITY TEST LOG word (KSB+68) when usblog
    is in too (RED stream). Without bbox t_bbx stays 0."""
    if 'bbox' not in placed:
        return data
    name = 'touchaudiot' if 'touchaudiot' in placed else 'touchaudio'
    if name not in placed:
        raise SystemExit('patch_main: bbox needs touchaudio (it runs in its TchAud task)')
    out = bytearray(data)
    o = lambda a: a - 0x08000000
    with open(blob_path(name), 'rb') as f:
        blob = f.read()
    mk = struct.pack('<I', BBOX_MARK)
    i = blob.find(mk)
    if i < 0 or blob.find(mk, i + 1) >= 0 or i % 4 or blob[i + 4:i + 8] != bytes(4):
        raise SystemExit('patch_main: bbox: t_bbx marker not found once in %s' % name)
    bb = placed['bbox']
    if out[o(bb) + 20:o(bb) + 24] != b'BBOX':
        raise SystemExit('patch_main: bbox: no BBOX magic at %#x' % bb)
    struct.pack_into('<I', out, o(placed[name]) + i + 4, bb)
    ksb = BBOX_KSB if out[o(BBOX_KSB) + 44:o(BBOX_KSB) + 48] == b'TFSK' else 0
    struct.pack_into('<I', out, o(bb) + 16, ksb)
    struct.pack_into('<I', out, o(bb) + 12, ksb + 68 if ksb and 'usblog' in placed else 0)
    print('patch_main: bbox at %#x: TchAud (%s) t_bbx -> it, KSB %#x, TEST LOG word %#x' % (
        bb, name, ksb, ksb + 68 if ksb and 'usblog' in placed else 0))
    return bytes(out)


def _place_tests(data, placed, blob_path):
    data = place_artj(data, placed, blob_path)
    data = place_bbox(data, placed, blob_path)
    if 'usblog' in placed:
        data = place_hudgrab(data, placed['usblog'])
    if 'autotest' in placed:
        data = place_autotest(data, placed['autotest'])
    if 'touchaudiot' in placed:
        data = place_testhooks(data, placed, blob_path)
    return data


def _mod_set(names):
    return {n: m for n, m in MODS.items() if n not in OPT_IN or n in names}


def patch(data, names, layout='stock'):
    if build_profile() == 'release' and any(n in names for n in DEV_ONLY):
        raise SystemExit('patch_main: CDJ_PROFILE=release names dev tooling: %s'
                         % ', '.join(n for n in names if n in DEV_ONLY))
    fixed = [n for n in names if n in FIXED and n not in ('modsmenu', 'keyshift', 'reclaim', 'ownks')]
    if 'ownks' in names and 'keyshift' not in names:
        raise SystemExit('patch_main: ownks is the engine behind keyshift: name both')
    mods = _test_names([n for n in names if n in MODS])
    layout = layout_for(names, layout)
    if 'keyshift' in names:     # V4k: the engine + front end first (it frees the DSP table area)
        sys.path.insert(0, os.path.join(HERE, 'keyshift'))
        import keyshift
        data = keyshift.apply(data, own='ownks' in names)
    if layout == 'stock':
        data = place_fixed(data, fixed)
        placed = {}
        data = sigpatch.patch(MAIN_PROFILE, blob_path, data, _mod_set(mods), mods, tag='patch_main',
                              placed=placed)
        if 'usbkey' in placed:
            data = place_usbkey(data, placed['usbkey'])
        data = _place_tests(data, placed, blob_path)
        data = apply_main_pokes(data, names)
        data = place_modsmenu(data, layout) if 'modsmenu' in names else data
        return place_reclaim(data, names)
    # V4n: TEST builds get UTILITY TEST LOG (OFF / USB / RED); V4n37r: the BLACK BOX row with mods/bbox.
    # Set (or cleared) before assemble(): build_modsmenu's block_end feeds FA_HI.
    os.environ['CDJ_TESTLOG'] = '1' if 'usblog' in names else '0'
    os.environ['CDJ_BBOX'] = '1' if 'bbox' in names else '0'
    os.environ['CDJ_LINK0B'] = '1' if 'link0btx' in names else '0'      # LINK0B (v4.2): its UTILITY row
    if os.environ.get('CDJ_KSAB') == '1' and ('ownks' not in names or 'usblog' not in names):
        raise SystemExit('patch_main: CDJ_KSAB=1 (KS3 A/B test switch) needs ownks and a DEV build (usblog)')
    lay = LAYOUTS[layout]
    check_free(data, lay['ramb'], lay['ramb'] + 0x20000, 'run-time block RAMB')
    data = place_fixed(data, fixed, layout)
    lo, hi = lay['code']
    check_free(data, lo, hi, 'code range')
    profile = MAIN_PROFILE._replace(ram_base=lo, ram_end=hi)
    with tempfile.TemporaryDirectory() as tmp:
        assemble(layout, tmp, quiet=True)      # sigpatch sizes every routine of the set
        placed = {}
        data = sigpatch.patch(profile, lambda n: os.path.join(tmp, n + '.bin'), data, _mod_set(mods), mods,
                              tag='patch_main[%s]' % layout, placed=placed)
        data = _place_tests(data, placed, lambda n: os.path.join(tmp, n + '.bin'))
    if 'usbkey' in placed:
        data = place_usbkey(data, placed['usbkey'])
    if 'jogtest' in placed:
        data = place_jogtest(data, placed['jogtest'])
    if 'jogcue' in placed:
        data = place_jogcue(data, placed['jogcue'])
    data = apply_main_pokes(data, names)
    data = place_modsmenu(data, layout) if 'modsmenu' in names else data
    return place_reclaim(data, names)


def place_reclaim(data, names):
    """reclaim (opt-in): last, so its stock check sees every other mod's bytes (mods/reclaim/reclaim.py)."""
    if 'reclaim' not in names:
        return data
    sys.path.insert(0, os.path.join(HERE, 'reclaim'))
    import reclaim
    return reclaim.apply(data)


def patch_flash(flash, names):
    """Patch the packed MAIN application directly inside a flat flash image
    (flash.bin's own bytes, not the unpacked one -kernel loads)."""
    _, image = main_decode.decode_image(flash)
    patched = patch(image, names)
    packed = main_encode.encode_image(patched)
    if len(packed) > FLASH_WINDOW_END - main_decode.MAIN_IMG_OFF:
        raise SystemExit('patch_main: patched image (%d bytes) does not fit '
                         'the flash window' % len(packed))
    out = bytearray(flash)
    lo, hi = main_decode.MAIN_IMG_OFF, FLASH_WINDOW_END
    out[lo:hi] = b'\xff' * (hi - lo)      # erase the window, as the real updater does
    out[lo:lo + len(packed)] = packed
    return bytes(out)


DELAY_SLOT_BRANCHES = re.compile(r'^\s*(bra|bsr|bt/s|bf/s|jmp|jsr|rts|rte|bsrf|braf)\b')
DELAY_SLOT_HAZARDS = re.compile(
    r'^\s*(?:(?:ld|st|fw|adr)\b'                     # a multi-instruction macro
    r'|mova\b'                                        # a pc-relative address
    r'|mov\.[wl]\s+(?!r\d+\b)[A-Za-z_]\w*\s*,)')  # a pc-relative literal load


def check_delay_slots(src):
    """No multi-instruction macro and no pc-relative load in a branch delay
    slot: the second instruction of a macro runs after the branch (a `st` in a
    delay slot left the local pacer running, 2026-10-21), and SH-4 computes a
    delay-slot literal from the branch target (ROWMETA_RE.md). The assembler
    accepts both silently and QEMU hides the second."""
    lines = open(src).read().split('\n')
    code = [(n + 1, l.split('!', 1)[0]) for n, l in enumerate(lines)]
    code = [(n, l) for n, l in code if l.strip() and not l.strip().startswith('.')]
    bad = []
    for (n, l), (n2, l2) in zip(code, code[1:]):
        if DELAY_SLOT_BRANCHES.match(l) and DELAY_SLOT_HAZARDS.match(l2.split(':', 1)[-1] if ':' in l2.split()[0] else l2):
            bad.append('%s:%d: %s  <- delay slot: %s' % (os.path.basename(src), n2, l2.strip(), l.strip()))
    if bad:
        raise SystemExit('patch_main: a macro or pc-relative load in a delay slot:\n  ' + '\n  '.join(bad))


def assemble(layout='stock', outdir=None, names=None, quiet=False):
    """Assemble every MODS routine with a layout's RAMB/TADEC (layout.inc).
    The stock layout writes the committed .bin beside each source; another
    layout writes into outdir, for blob_path_in(outdir)."""
    lay = LAYOUTS[layout]
    for name in names or MODS:
        check_delay_slots(source(name))
    # utiltint classifies a UTILITY item by its label pointer against the
    # modsmenu block [entries, block_end); the bounds are fixed by the layout's
    # menu base, so build modsmenu once to read them.
    _, mm_syms = build_modsmenu(lay['menu'], layout)
    defs = ['--defsym', 'RAMB=%#x' % lay['ramb'], '--defsym', 'TADEC=%#x' % lay['tadec'],
            '--defsym', 'MODSV=%#x' % (lay['menu'] + 240),
            '--defsym', 'LCV=%#x' % (lay['menu'] + 244),
            '--defsym', 'W32V=%#x' % (lay['menu'] + 248),
            '--defsym', 'DIAGT=%#x' % (lay['menu'] + 256),
            '--defsym', 'DIAGL=%#x' % mm_syms['L_DIAG'],
            '--defsym', 'FA_LO=%#x' % mm_syms['entries'],
            '--defsym', 'FA_HI=%#x' % mm_syms['block_end'],
            '--defsym', 'MMPUB=%#x' % mm_syms['mm_publish'],
            '--defsym', 'BLDID=%#x' % (lay['menu'] + MM_BLD_OFF),      # V4n36 trace
            '--defsym', 'KILLB=%#x' % (lay['menu'] + MM_KILL_OFF)]
    if build_profile() == 'release' and layout != 'stock':  # V4n37r (the committed stock-layout .bins stay DEV)
        defs += ['--defsym', 'RELEASE=1']
    if os.environ.get('CDJ_LCDRV'):        # experiment: touch_audio's medium letter (D = LINKed)
        defs += ['--defsym', 'LCDRV=%d' % ord(os.environ['CDJ_LCDRV'][0])]
    with tempfile.TemporaryDirectory() as tmp:
        for name in names or MODS:
            obj = os.path.join(tmp, name + '.o')
            out = blob_path(name) if outdir is None else os.path.join(outdir, name + '.bin')
            subprocess.run(['sh4-linux-gnu-as', '--isa=sh4', '-little',
                            '-I', os.path.dirname(source(name)), '-I', HERE]
                           + defs + ['-o', obj, source(name)], check=True)
            subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary',
                            obj, out], check=True)
            if not quiet:
                print('patch_main: wrote %s (%d bytes)' % (out, os.path.getsize(out)))


def main():
    args = sys.argv[1:]
    if args == ['--assemble']:
        assemble()
        return
    if args == ['--list']:
        for name, (addr, rel, what) in FIXED.items():
            print('%-8s %s' % (name, what))
        for name, mod in MODS.items():
            print('%-8s %s' % (name, mod.what))
        return
    if args[:1] == ['--flash']:
        args = args[1:]
        flasher = True
    else:
        flasher = False
    if len(args) < 3 or any(n not in MODS and n not in FIXED for n in args[2:]):
        raise SystemExit(__doc__)
    with open(args[0], 'rb') as f:
        data = f.read()
    out = patch_flash(data, args[2:]) if flasher else patch(data, args[2:])
    with open(args[1], 'wb') as f:
        f.write(out)


if __name__ == '__main__':
    main()

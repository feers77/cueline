#!/usr/bin/env python3
"""stagehand.py -- pose as the Pioneer DJ "Stagehand" iPad app on Pro DJ Link (PC side only).

Port of the Stagehand support in chrisle/alphatheta-connect v0.28.5 (commit 7496991; MIT licence, see
LICENSE.alphatheta-connect). Everything is UDP -- the library has NO TCP path (no 50003); see STAGEHAND.md:223.

  join (broadcast, -> *:50000, src 50000)   src/virtualcdj/stagehand.ts:71-128,182-249
     0x0a announce x3 (37 B) -> 0x02 claim x3 (50 B, counter 1..3), 305 ms apart -> 0x06 keep-alive every 2 s
     (54 B). Device type byte 0x05 (src/types.ts:37), number 141..211 (stagehand.ts:42), protocol MAC =
     c8:3d:fc + low 3 bytes of the NIC MAC (stagehand.ts:34). Keep number+MAC STABLE per host: a CDJ-3000
     ignores a later claim from the same IP with another identity until it reboots (stagehand.ts:21-33,
     docs/REMOTE.md:104-108).
  heartbeat (unicast, src 50002 -> dev:50002, every 250 ms)   src/virtualcdj/heartbeat.ts:18,43-83,128-155
     mixer: 0x3a (40 B, constant trailer 21 02 00 fe 00 04 00 1c 00 00, byte-exact vs iPad -> DJM-A9)
     CDJ:   0x68 (36 B, body 03 01 00 3a 00 00). This is what makes the hardware stream TO us.
  mixer -> us (only after the heartbeat; parsed by src/status/utils.ts:235-313, layout RE'd on a DJM-A9)
     0x39 on 50002, >=266 B, ~4 Hz: name @11..29, crossfader @180, ch1..4 blocks @36+24*(ch-1):
          +1 trim, +3 eq hi, +4 eq mid, +6 eq low, +7 color fx, +11 fader, +12 xf assign (1 A, 2 B, else THRU)
          (0..255, unity 0x80 -- src/status/types.ts:229-240)
     0x58 on 50001, >=584 B, ~30 Hz: ch1..4 x 15 frames x (u16 BE left, u16 BE right) @44+60*(ch-1).
          Bytes 284..583 are not decoded upstream (master/booth/ch5-6? -> we keep them for the hunt).
  us -> CDJ (src/control/stagehand.ts:27-124, src/control/index.ts:53-203; captured from the iPad)
     0x07 transport, 48 B, src 50001 -> CDJ:50001: name19 @11, 03 01 00 @30, corr @33, len 0x0030 @34,
          3a @39, 01 @41, op @43, press @45. ops: 0x0f+0x14(press)=PLAY, 0x14(release)=PAUSE, 0x18 SKIP,
          0x1a SEEK FWD hold, 0x1b SEEK BACK hold. No absolute seek exists in the protocol.
     0x6b preference write, 116 B, src 50001 -> CDJ:50002: 03 01 00 3a @30, len 0x0050 @34, 01 @36 (write),
          on-air @44 (0x81 ON / 0x80 OFF / 0 untouched), quantize @60 (0x80|index).
  UNVERIFIED upstream: the CDJ-3000 never executed 0x07 from the library (docs/REMOTE.md:77-102,
  STAGEHAND.md:194-235): the iPad gets a 0x69 session token (54 B -> 50002, bytes 40-43) and a 0x0b stream
  (60 B -> 50001); byte 33 "correlation" seems derived from that token. Byte 30 may be the TARGET PLAYER number
  (STAGEHAND.md:200-212) -- the captured frames carry 0x03; we expose it as --target. Every iPad capture had a
  DJM-A9 on the net (REMOTE.md:99-102). The mixer read path (0x39/0x58) is the useful part for us.

Writes (0x07 transport, 0x6b prefs) are refused unless --allow-write. Join + heartbeat are always sent (needed
to receive anything); use --dry-run to print every frame without opening a socket.

CLI (real LAN only -- the user's rig; never in CI):
  stagehand.py watch --mixer IP [--sec N] [--json]                print faders/EQ (on change) + VU 5x/s
  stagehand.py cdj IP play|pause|skip|seek SEC|onair on|off|quantize N  [--allow-write] [--target P]
  stagehand.py selftest                                           offline: replay upstream fixtures
  common: --me MY_IP (default: route to the target)  --bcast ADDR  --id 141..211  --name Stagehand  --dry-run

------------------------------------------------------------------------------------------------------------
Portions ported from alphatheta-connect (https://github.com/chrisle/alphatheta-connect, Chris Le), a fork of
prolink-connect (https://github.com/EvanPurkhiser/prolink-connect). MIT License:

Copyright (c) 2013 Evan Purkhiser

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
"""
import collections
import json
import os
import random
import socket
import struct
import sys
import threading
import time
import zlib

MAGIC = b'Qspt1WmJOL'
P_ANN, P_BEAT, P_STAT = 50000, 50001, 50002
DEVTYPE_CDJ, DEVTYPE_MIXER, DEVTYPE_RB, DEVTYPE_STAGEHAND = 1, 3, 4, 5        # src/types.ts:34-37
STARTUP_INTERVAL, KEEPALIVE_INTERVAL, HEARTBEAT_INTERVAL = 0.305, 2.0, 0.250  # stagehand.ts:12-13, heartbeat.ts:18
OP_PLAY, OP_PLAYPAUSE, OP_SKIP, OP_SEEK_FWD, OP_SEEK_BACK = 0x0f, 0x14, 0x18, 0x1a, 0x1b   # control/index.ts:120-191
VU_MAX = 65535
XF = {1: 'A', 2: 'B'}


class WriteRefused(PermissionError):
    pass


# ------------------------------------------------------------------------------------------------- identity
def stagehand_mac(nic_mac):
    """AlphaTheta OUI c8:3d:fc + low 3 bytes of the NIC MAC (stagehand.ts:34-37)."""
    return b'\xc8\x3d\xfc' + bytes(nic_mac[3:6])


def stable_number(mac):
    """141..211 like the app (stagehand.ts:42), but deterministic per MAC (one identity per address, always)."""
    return 141 + zlib.crc32(bytes(mac)) % 71


def nic_mac_for_ip(ip):
    """Linux: the MAC of the interface holding `ip` (falls back to uuid.getnode())."""
    try:
        import fcntl
        for ifn in os.listdir('/sys/class/net'):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                a = fcntl.ioctl(s.fileno(), 0x8915, struct.pack('256s', ifn.encode()[:15]))   # SIOCGIFADDR
                if socket.inet_ntoa(a[20:24]) == ip:
                    return bytes.fromhex(open('/sys/class/net/%s/address' % ifn).read().strip().replace(':', ''))
            except OSError:
                pass
            finally:
                s.close()
    except (ImportError, OSError):
        pass
    import uuid
    return uuid.getnode().to_bytes(6, 'big')


def route_ip(dst):
    """Local address the kernel would use toward dst (UDP connect: no packet is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((dst, P_ANN))
        return s.getsockname()[0]
    finally:
        s.close()


def default_bcast(ip):
    return '169.254.255.255' if ip.startswith('169.254.') else ip.rsplit('.', 1)[0] + '.255'


# ------------------------------------------------------------------------------------------------- frames
def name_field(name, n):
    """20 B for the broadcast frames (utils/index.ts:10), 19 B for unicast ones (heartbeat.ts:28)."""
    return name.encode('ascii', 'replace')[:n].ljust(n, b'\0')


def pkt_announce_0a(name):                                   # stagehand.ts:71-81 (37 B)
    return MAGIC + b'\x0a\x00' + name_field(name, 20) + b'\x01\x03\x00\x25' + bytes([DEVTYPE_STAGEHAND])


def pkt_claim_02(name, ip4, mac, counter):                  # stagehand.ts:87-106 (50 B)
    return (MAGIC + b'\x02\x00' + name_field(name, 20) + b'\x01\x03\x00\x32' + ip4 + bytes(mac) +
            bytes([0x3a, counter, DEVTYPE_STAGEHAND, 0x01]))


def pkt_keepalive_06(name, number, mac, ip4):               # stagehand.ts:112-128 (54 B)
    return (MAGIC + b'\x06\x00' + name_field(name, 20) + b'\x01\x03\x00\x36' + bytes([number, 0x01]) + bytes(mac) +
            ip4 + b'\x01\x00\x00\x00' + bytes([DEVTYPE_STAGEHAND, 0x20]))


def pkt_mixer_hb_3a(name):                                  # heartbeat.ts:43-60 (40 B)
    return MAGIC + b'\x3a' + name_field(name, 19) + bytes.fromhex('210200fe0004001c0000')


def pkt_player_hb_68(name, target=3):                       # heartbeat.ts:70-83 (36 B); [30] = target? (doc :200)
    return MAGIC + b'\x68' + name_field(name, 19) + bytes([target, 0x01, 0x00, 0x3a, 0x00, 0x00])


def pkt_state_sync_3c(name, target=3):                      # STAGEHAND.md:202 (36 B, never built upstream)
    return MAGIC + b'\x3c' + name_field(name, 19) + bytes([target, 0x01, 0x00, 0x3a, 0x00, 0x00])


def pkt_transport_07(name, op, press, corr, target=3):      # control/stagehand.ts:27-69 (48 B)
    p = bytearray(48)
    p[0:10] = MAGIC
    p[10] = 0x07
    p[11:30] = name_field(name, 19)
    p[30:33] = bytes([target, 0x01, 0x00])
    p[33] = corr & 0xff
    p[34:36] = b'\x00\x30'
    p[39], p[41], p[43], p[45] = 0x3a, 0x01, op, 1 if press else 0
    return bytes(p)


def pkt_pref_6b(name, onair=None, quantize=None, target=3):  # control/stagehand.ts:81-124 (116 B)
    p = bytearray(116)
    p[0:10] = MAGIC
    p[10] = 0x6b
    p[11:30] = name_field(name, 19)
    p[30:34] = bytes([target, 0x01, 0x00, 0x3a])
    p[34:36] = b'\x00\x50'
    p[36] = 0x01
    if onair is not None:
        p[44] = 0x81 if onair else 0x80
    if quantize is not None:
        p[60] = 0x80 | (quantize & 0x7f)
    return bytes(p)


# ------------------------------------------------------------------------------------------------- parsers
def parse_mixer_state(d):
    """0x39 (status/utils.ts:235-282). Returns None if not a mixer-state frame."""
    if d[:10] != MAGIC or len(d) < 266 or d[10] != 0x39:
        return None
    chans = {}
    for ch in range(1, 5):
        o = 36 + (ch - 1) * 24
        chans[ch] = dict(trim=d[o + 1], eq_hi=d[o + 3], eq_mid=d[o + 4], eq_low=d[o + 6], color_fx=d[o + 7],
                         fader=d[o + 11], xf_assign=XF.get(d[o + 12], 'THRU'))
    return dict(name=d[11:30].rstrip(b'\0').decode('latin1').strip(), crossfader=d[180], channels=chans,
                length=len(d))


def parse_vu(d):
    """0x58 (status/utils.ts:288-313): {ch: [(left, right) x 15]} + undecoded tail."""
    if d[:10] != MAGIC or len(d) < 584 or d[10] != 0x58:
        return None
    chans = {}
    for ch in range(1, 5):
        o = 44 + (ch - 1) * 60
        chans[ch] = [struct.unpack_from('>HH', d, o + 4 * i) for i in range(15)]
    return dict(channels=chans, tail=bytes(d[284:]), length=len(d))


def vu_peak(frames):
    """0..1 peak of a 15-frame window (both sides)."""
    return max(max(l, r) for l, r in frames) / VU_MAX if frames else 0.0


# ------------------------------------------------------------------------------------------------- transports
class DryNet:
    """No sockets: every frame is printed (or collected) instead of sent."""
    lan = False

    def __init__(self, my_ip='169.254.1.2', bcast='169.254.255.255', mac=b'\x02\0\0\0\x12\x34', quiet=False):
        self.my_ip, self.bcast, self.ip, self.mac = my_ip, bcast, socket.inet_aton(my_ip), mac
        self.sent, self.quiet = [], quiet

    def send(self, dst_ip, dport, pay, sport=None):
        self.sent.append((dst_ip, dport, sport or dport, pay))
        if not self.quiet:
            print('DRY %s:%d <- :%d  %3d B  %s' % (dst_ip, dport, sport or dport, len(pay), pay.hex()), flush=True)

    def recv(self, timeout):
        time.sleep(min(timeout, 0.05))
        return None


# ------------------------------------------------------------------------------------------------- client
class Stagehand:
    """A virtual Stagehand. `net` is a prodjlink transport (UdpNet / McastSeg) or DryNet.

    own_rx=True: we read `net` ourselves (standalone CLI). own_rx=False: someone else (prodjlink.Link via
    link.taps) calls feed(src, sport, dport, data) -- share ONE transport, never bind 50000-50002 twice.
    """

    def __init__(self, net, name='Stagehand', number=None, mac=None, mixers=(), cdjs=(), target=3,
                 allow_write=False, on_event=None, own_rx=True, corr=None):
        self.net, self.name, self.target = net, name, target
        nic = mac or getattr(net, 'mac', b'') or b''
        if not nic or nic == b'\0' * 6:
            nic = nic_mac_for_ip(socket.inet_ntoa(net.ip))
        self.mac = stagehand_mac(nic)
        self.number = number or stable_number(self.mac)
        self.allow_write, self.own_rx = allow_write, own_rx
        self.on_event = on_event or (lambda k, e: None)
        self.corr = random.randrange(256) if corr is None else corr     # control/index.ts:53-65 (per session)
        self.mixers, self.cdjs = set(mixers), set(cdjs)                 # IPs to heartbeat
        self.devices = {}                                               # ip -> keepalive info
        self.mixer = None                                               # latest 0x39 (dict)
        self.vu = {}                                                    # ch -> latest 15 frames
        self.vu_hist = collections.deque(maxlen=3000)                   # (t, {ch: peak}) ~100 s at 30 Hz
        self.vu_tail_var = set()
        self._vu_tail0 = None
        self.counts = collections.Counter()
        self.tokens = []                                                # 0x69 frames (session token?)
        self.cond = threading.Condition()
        self.run_ = False
        self.joined = threading.Event()

    # ---- lifecycle
    def start(self):
        self.run_ = True
        threading.Thread(target=self._announce, daemon=True).start()
        threading.Thread(target=self._heartbeat, daemon=True).start()
        if self.own_rx:
            threading.Thread(target=self._rx, daemon=True).start()
        return self

    def stop(self):
        self.run_ = False

    def _bsend(self, pay):
        self.net.send(self.net.bcast, P_ANN, pay, sport=P_ANN)

    def _announce(self):
        """0x0a x3, 0x02 x3 (counter 1..3), 305 ms apart, then 0x06 every 2 s (stagehand.ts:182-249)."""
        ip4 = self.net.ip
        for i in range(3):
            self._bsend(pkt_announce_0a(self.name))
            time.sleep(STARTUP_INTERVAL)
        for n in (1, 2, 3):
            self._bsend(pkt_claim_02(self.name, ip4, self.mac, n))
            time.sleep(STARTUP_INTERVAL)
        self.joined.set()
        self.on_event('stagehand_joined', dict(number=self.number, mac=self.mac.hex(':'), name=self.name))
        while self.run_:
            self._bsend(pkt_keepalive_06(self.name, self.number, self.mac, ip4))
            for _ in range(int(KEEPALIVE_INTERVAL / 0.1)):
                if not self.run_:
                    return
                time.sleep(0.1)

    def _heartbeat(self):
        """Unicast 0x3a to mixers / 0x68 to CDJs from 50002 to 50002, 4 Hz (heartbeat.ts:128-155).
        Upstream starts it right after the announcer (network.ts:377-391), not after the join completes."""
        while self.run_:
            with self.cond:
                mixers, cdjs = list(self.mixers), list(self.cdjs)
            for ip in mixers:
                self.net.send(ip, P_STAT, pkt_mixer_hb_3a(self.name), sport=P_STAT)
            for ip in cdjs:
                self.net.send(ip, P_STAT, pkt_player_hb_68(self.name, self.target), sport=P_STAT)
            time.sleep(HEARTBEAT_INTERVAL)

    def _rx(self):
        while self.run_:
            try:
                r = self.net.recv(0.2)
            except OSError:
                continue
            if r:
                self.feed(*r)

    # ---- receive
    def feed(self, src, sp, dp, d):
        if d[:10] != MAGIC or len(d) < 11:
            return
        t = d[10]
        self.counts[(dp, t)] += 1
        now = time.time()
        ev = None
        with self.cond:
            if dp == P_ANN and t == 0x06 and len(d) >= 0x36:
                dtype, num = d[0x34], d[0x24]
                info = dict(ip=src, dev=num, type=dtype, name=d[0x0c:0x20].rstrip(b'\0').decode('latin1'))
                if src not in self.devices and dtype != DEVTYPE_STAGEHAND:
                    ev = ('stagehand_peer', info)
                self.devices[src] = info
                if dtype == DEVTYPE_MIXER:                  # devices/utils.ts:31 -> heartbeat.ts:136-145
                    self.mixers.add(src)
                elif dtype == DEVTYPE_CDJ and 1 <= num <= 6:
                    self.cdjs.add(src)
            elif dp == P_STAT and t == 0x39:
                m = parse_mixer_state(d)
                if m:
                    m['ip'], m['t'] = src, now
                    old = self.mixer
                    self.mixer = m
                    if old is None or old['channels'] != m['channels'] or old['crossfader'] != m['crossfader']:
                        ev = ('mixer_state', m)
            elif dp == P_BEAT and t == 0x58:
                v = parse_vu(d)
                if v:
                    self.vu = v['channels']
                    self.vu_hist.append((now, {ch: vu_peak(f) for ch, f in v['channels'].items()}))
                    if self._vu_tail0 is None:
                        self._vu_tail0 = v['tail']
                    else:
                        self.vu_tail_var.update(284 + i for i, (a, b) in enumerate(zip(self._vu_tail0, v['tail']))
                                                if a != b)
            elif t == 0x69:
                self.tokens.append((now, src, d))
                ev = ('stagehand_token', dict(src=src, len=len(d), token=d[40:44].hex(), hex=d.hex()))
            elif self.counts[(dp, t)] == 1 and t not in (0x0a, 0x00, 0x02, 0x04, 0x06, 0x28, 0x03):
                ev = ('stagehand_new_kind', dict(src=src, port=dp, type=t, len=len(d), hex=d[:96].hex()))
            self.cond.notify_all()
        if ev:
            self.on_event(*ev)

    # ---- queries (for rig assertions)
    def vu_level(self, ch, window=1.0):
        """Peak 0..1 of channel `ch` over the last `window` seconds (None if no VU frame in that window)."""
        t0 = time.time() - window
        with self.cond:
            vals = [p[ch] for t, p in self.vu_hist if t >= t0 and ch in p]
        return max(vals) if vals else None

    def wait(self, pred, timeout):
        end = time.monotonic() + timeout
        with self.cond:
            while True:
                r = pred()
                if r or time.monotonic() >= end:
                    return r
                self.cond.wait(min(0.2, max(0.01, end - time.monotonic())))

    def stats(self):
        return dict(number=self.number, mac=self.mac.hex(':'), mixers=sorted(self.mixers), cdjs=sorted(self.cdjs),
                    counts={'%d/0x%02x' % k: v for k, v in sorted(self.counts.items())},
                    vu_frames=len(self.vu_hist), vu_tail_varying=sorted(self.vu_tail_var)[:64],
                    tokens=len(self.tokens))

    # ---- writes (refused unless allow_write)
    def _write(self, ip, dport, pay, sport):
        if not self.allow_write:
            raise WriteRefused('write to %s:%d refused (read-only; pass --allow-write): %s' % (ip, dport, pay.hex()))
        self.on_event('stagehand_write', dict(ip=ip, port=dport, hex=pay.hex()))
        self.net.send(ip, dport, pay, sport=sport)

    def transport(self, ip, op, press):
        self._write(ip, P_BEAT, pkt_transport_07(self.name, op, press, self.corr, self.target), P_BEAT)

    def play(self, ip):                                      # control/index.ts:121-136
        self.transport(ip, OP_PLAY, True)
        self.transport(ip, OP_PLAYPAUSE, True)

    def pause(self, ip):                                     # control/index.ts:142-150
        self.transport(ip, OP_PLAYPAUSE, False)

    def skip(self, ip, hold=0.1):                            # control/index.ts:184-192 (press, release)
        self.transport(ip, OP_SKIP, True)
        time.sleep(hold)
        self.transport(ip, OP_SKIP, False)

    def seek(self, ip, sec):
        """No absolute seek in Stagehand: hold SEARCH fwd (sec>0) / back (sec<0) for |sec| s of wall time."""
        op = OP_SEEK_FWD if sec >= 0 else OP_SEEK_BACK
        self.transport(ip, op, True)
        time.sleep(abs(sec))
        self.transport(ip, op, False)

    def set_pref(self, ip, onair=None, quantize=None):       # control/index.ts:197-203 (sent from the beat socket)
        self._write(ip, P_STAT, pkt_pref_6b(self.name, onair, quantize, self.target), P_BEAT)


# ------------------------------------------------------------------------------------------------- selftest
# Captured iPad frames pinned upstream (hex copied verbatim; sources cited per entry).
FIXTURES = {
    'mixer_hb_3a': ('heartbeat.test.ts:23-29', '5173707431576d4a4f4c3a537461676568616e6400000000000000000000'
                    '210200fe0004001c0000'),
    'player_hb_68': ('heartbeat.test.ts:31-38', '5173707431576d4a4f4c68537461676568616e6400000000000000000000'
                     '0301003a0000'),
    'play_0f': ('tests/control/stagehand.spec.ts:32-33', '5173707431576d4a4f4c07537461676568616e64000000000000000000'
                '00030100f700300000003a0001000f00010000'),
    'play_14': ('tests/control/stagehand.spec.ts:34-35', '5173707431576d4a4f4c07537461676568616e64000000000000000000'
                '00030100e800300000003a0001001400010000'),
    'seek_fwd_release': ('tests/control/stagehand.spec.ts:37-38', '5173707431576d4a4f4c07537461676568616e6400000000'
                         '000000000000030100ed00300000003a0001001a00000000'),
    'onair_on': ('tests/control/stagehand.spec.ts:91-92', '5173707431576d4a4f4c6b537461676568616e64000000000000000000000301003a00500100000000000000810000000000'
                 '000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'),
}


def selftest():
    ok = True

    def check(what, cond, info=''):
        nonlocal ok
        ok &= bool(cond)
        print('%-4s %s %s' % ('ok' if cond else 'FAIL', what, info))

    built = {
        'mixer_hb_3a': pkt_mixer_hb_3a('Stagehand'),
        'player_hb_68': pkt_player_hb_68('Stagehand'),
        'play_0f': pkt_transport_07('Stagehand', OP_PLAY, True, 0xf7),
        'play_14': pkt_transport_07('Stagehand', OP_PLAYPAUSE, True, 0xe8),
        'seek_fwd_release': pkt_transport_07('Stagehand', OP_SEEK_FWD, False, 0xed),
        'onair_on': pkt_pref_6b('Stagehand', onair=True),
    }
    for k, (src, hx) in FIXTURES.items():
        want = bytes.fromhex(hx)
        check('builder %-17s == iPad capture (%s)' % (k, src), built[k] == want, '%d B' % len(want))
    # join frames: sizes and fixed bytes asserted upstream (tests/virtualcdj/stagehand.test.ts:58-97)
    ip4, mac = socket.inet_aton('192.168.1.100'), stagehand_mac(bytes.fromhex('001122334455'))
    a, c, k = pkt_announce_0a('Stagehand'), pkt_claim_02('Stagehand', ip4, mac, 1), pkt_keepalive_06('Stagehand', 150,
                                                                                                    mac, ip4)
    check('0x0a 37 B / [32..33]=01 03 / [36]=05', len(a) == 37 and a[32:34] == b'\1\3' and a[36] == 5)
    check('0x02 50 B / [46]=3a [47]=ctr [48]=05 [49]=01', len(c) == 50 and tuple(c[46:50]) == (0x3a, 1, 5, 1))
    check('0x06 54 B / [36]=150 [52]=05 [53]=20', len(k) == 54 and k[36] == 150 and k[52] == 5 and k[53] == 0x20)
    check('mac c8:3d:fc:33:44:55 (stagehand.test.ts:30)', mac == bytes.fromhex('c83dfc334455'))
    check('pref 116 B, quantize 2 -> [60]=0x82', pkt_pref_6b('S', onair=True, quantize=2)[60] == 0x82)
    # parsers: the upstream synthetic frames (tests/status/utils.spec.ts:109-131, 199-218) -- no real 0x39/0x58
    # capture is published, so these only pin the offsets.
    m = bytearray(266)
    m[:10], m[10] = MAGIC, 0x39
    m[11:17] = b'DJM-A9'
    m[180] = 120
    for ch in range(1, 5):
        o = 36 + (ch - 1) * 24
        m[o + 1], m[o + 3], m[o + 4], m[o + 6], m[o + 7], m[o + 11] = (100 + ch, 110 + ch, 120 + ch, 130 + ch,
                                                                       140 + ch, 150 + ch)
        m[o + 12] = {1: 1, 2: 2}.get(ch, 0)
    ms = parse_mixer_state(bytes(m))
    check('0x39 parse', ms and ms['name'] == 'DJM-A9' and ms['crossfader'] == 120 and
          ms['channels'][1] == dict(trim=101, eq_hi=111, eq_mid=121, eq_low=131, color_fx=141, fader=151,
                                    xf_assign='A') and ms['channels'][2]['xf_assign'] == 'B' and
          ms['channels'][4]['fader'] == 154 and ms['channels'][3]['xf_assign'] == 'THRU')
    v = bytearray(584)
    v[:10], v[10] = MAGIC, 0x58
    for ch in range(1, 5):
        for i in range(15):
            struct.pack_into('>HH', v, 44 + (ch - 1) * 60 + 4 * i, 1000 * ch + i, 2000 * ch + i)
    vs = parse_vu(bytes(v))
    check('0x58 parse', vs and vs['channels'][1][0] == (1000, 2000) and vs['channels'][1][14] == (1014, 2014) and
          vs['channels'][4][0] == (4000, 8000) and vs['channels'][4][14] == (4014, 8014))
    # client replay offline: DryNet, feed the frames, check state + write gate
    net = DryNet(quiet=True)
    sh = Stagehand(net, number=150, mac=bytes.fromhex('001122334455'), mixers=['169.254.142.194'], own_rx=False)
    sh.feed('169.254.142.194', 50002, 50002, bytes(m))
    sh.feed('169.254.142.194', 50001, 50001, bytes(v))
    check('client: mixer_state + vu_level', sh.mixer['channels'][3]['fader'] == 153 and
          abs(sh.vu_level(4) - 8014 / VU_MAX) < 1e-9)
    try:
        sh.play('169.254.0.10')
        check('client: write refused without allow_write', False)
    except WriteRefused:
        check('client: write refused without allow_write', not net.sent)
    sh.allow_write, sh.corr = True, 0xf7
    sh.transport('169.254.0.10', OP_PLAY, True)
    check('client: allowed write -> CDJ:50001 from :50001', net.sent[-1][:3] == ('169.254.0.10', 50001, 50001) and
          net.sent[-1][3] == bytes.fromhex(FIXTURES['play_0f'][1]))
    print('selftest', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


# ------------------------------------------------------------------------------------------------- CLI
def fmt_mixer(m):
    s = ['xf=%3d' % m['crossfader']]
    for ch, c in m['channels'].items():
        s.append('ch%d fad=%3d trim=%3d eq=%3d/%3d/%3d cfx=%3d %s' % (ch, c['fader'], c['trim'], c['eq_hi'],
                                                                     c['eq_mid'], c['eq_low'], c['color_fx'],
                                                                     c['xf_assign']))
    return ' | '.join(s)


def vu_bar(x, w=20):
    n = int(round((x or 0) * w))
    return '#' * n + '.' * (w - n)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split('------')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['watch', 'cdj', 'selftest'])
    ap.add_argument('ip', nargs='?', help='cdj: the player IP')
    ap.add_argument('action', nargs='*', help='cdj: play | pause | skip | seek SEC | onair on|off | quantize N')
    ap.add_argument('--mixer', action='append', default=[], help='mixer IP to heartbeat (repeatable)')
    ap.add_argument('--me', help='this PC\'s DJ Link address (default: route toward the target)')
    ap.add_argument('--bcast')
    ap.add_argument('--id', type=int, help='Stagehand number 141..211 (default: stable from MAC)')
    ap.add_argument('--name', default='Stagehand')
    ap.add_argument('--target', type=int, default=3, help='byte 30 of unicast frames (iPad captures: 3)')
    ap.add_argument('--corr', type=lambda x: int(x, 0), help='byte 33 of 0x07 (default random per session)')
    ap.add_argument('--sec', type=float, default=1e9)
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--allow-write', action='store_true', help='actually send 0x07 / 0x6b (default: refuse)')
    ap.add_argument('--dry-run', action='store_true', help='print frames, open no socket')
    ap.add_argument('--settle', type=float, default=2.5, help='cdj: seconds after join before the command')
    a = ap.parse_args(argv)
    if a.cmd == 'selftest':
        return selftest()
    ref = a.ip if a.cmd == 'cdj' else (a.mixer[0] if a.mixer else None)
    if not ref:
        ap.error('watch needs --mixer IP; cdj needs IP')
    me = a.me or ('169.254.1.2' if a.dry_run else route_ip(ref))
    bcast = a.bcast or default_bcast(me)

    def ev(k, e):
        if a.json:
            print(json.dumps(dict(t=round(time.time(), 3), ev=k, **{x: y for x, y in e.items() if x != 't'}),
                         default=str), flush=True)
        elif k == 'mixer_state':
            print('%.3f MIXER %s %s' % (time.time(), e['name'], fmt_mixer(e)), flush=True)
        else:
            print('%.3f %s %s' % (time.time(), k, json.dumps(e, default=str)[:300]), flush=True)

    if a.dry_run:
        net = DryNet(me, bcast)
    else:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import prodjlink
        net = prodjlink.UdpNet(me, bcast=bcast, ports=(P_ANN, P_BEAT, P_STAT))
    sh = Stagehand(net, a.name, a.id, mixers=a.mixer, cdjs=[a.ip] if a.cmd == 'cdj' else [], target=a.target,
                   allow_write=a.allow_write, on_event=ev, corr=a.corr).start()
    print('stagehand: me=%s bcast=%s number=%d mac=%s corr=0x%02x write=%s%s' % (
        me, bcast, sh.number, sh.mac.hex(':'), sh.corr, 'ALLOWED' if a.allow_write else 'refused',
        ' DRY-RUN' if a.dry_run else ''), file=sys.stderr, flush=True)
    try:
        if a.cmd == 'watch':
            end, nxt = time.monotonic() + a.sec, 0
            while time.monotonic() < end:
                time.sleep(0.05)
                if time.monotonic() >= nxt and sh.vu_hist:
                    nxt = time.monotonic() + 0.2
                    lv = {ch: sh.vu_level(ch, 0.2) for ch in range(1, 5)}
                    if a.json:
                        print(json.dumps(dict(t=round(time.time(), 3), ev='vu', peak=lv)), flush=True)
                    else:
                        print('%.3f VU ' % time.time() + '  '.join('ch%d %s %.3f' % (ch, vu_bar(x), x or 0)
                                                                  for ch, x in lv.items()), flush=True)
            return 0
        act = a.action
        if not act:
            ap.error('cdj needs an action')
        sh.joined.wait(5)
        time.sleep(a.settle)
        if act[0] == 'play':
            sh.play(a.ip)
        elif act[0] == 'pause':
            sh.pause(a.ip)
        elif act[0] == 'skip':
            sh.skip(a.ip)
        elif act[0] == 'seek':
            sh.seek(a.ip, float(act[1]))
        elif act[0] == 'onair':
            sh.set_pref(a.ip, onair=act[1] == 'on')
        elif act[0] == 'quantize':
            sh.set_pref(a.ip, quantize=int(act[1]))
        else:
            ap.error('unknown action %r' % act[0])
        time.sleep(1.5)                                      # catch a 0x69 / 0x0b reaction
        return 0
    except WriteRefused as e:
        print('REFUSED: %s' % e, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 0
    finally:
        sh.stop()
        print(json.dumps(sh.stats()), file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

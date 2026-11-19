#!/usr/bin/env python3
"""prodjlink.py -- a small Pro DJ Link library + CLI for the real-rig tests (PC side only).

Transports
  UdpNet(my_ip, bcast)          real LAN: UDP sockets bound to 50000/50001/50002/50099 (+ SO_BROADCAST).
  McastSeg('G:P', my_ip, mac)   emulator: QEMU `-netdev socket,mcast=G:P` segment = one raw Ethernet frame per
                                datagram. We build Ethernet/IPv4/UDP frames ourselves, answer ARP for my_ip and
                                learn the decks' MACs from their frames. Nothing leaves the host's mcast loop.

Link(transport, number, name, kind)   a virtual device: keepalive on 50000 (kind 'cdj' | 'mixer' | 'rekordbox'),
  receiver thread with discovery (devices), latest status per device (CDJ 0x0a NXS2/3000, mixer 0x29),
  beats (0x28), mixer on-air (0x03), command acks, an unknown-packet catalogue with per-byte variance
  (to find the DJM-A9 level/meter fields on the real rig), and commands:
    fader_start(target, {player: 'start'|'stop'})     type 0x02 -> 50001  (beat-link sendFaderStartCommand)
    load_track(target, src_player, slot, rbid, ttype) type 0x19 -> 50002, ack 0x1a (beat-link sendLoadTrackCommand)
    sync(target, on) / become_master(target)          type 0x2a -> 50001  (sync control: 0x10 on, 0x20 off, 0x01 master)
    on_air(flags)                                     type 0x03 -> 50001 broadcast (what a mixer sends; 4 channels)
  Field offsets: dysentery "packets" doc / beat-link CdjStatus, MixerStatus, Beat; checked against the emulator
  (re/REAL_NXS2.md: the same status layout on a real NXS2 1.87).

CLI (emulator by default needs --mcast; --lan MY_IP for the real network -- only on the user's rig):
  prodjlink.py --mcast G:P watch [SEC]
  prodjlink.py --mcast G:P fader TARGET start|stop
  prodjlink.py --mcast G:P load TARGET SRC_PLAYER SLOT RBID [TTYPE]
  prodjlink.py --mcast G:P sync TARGET on|off  |  master TARGET  |  onair ANY_SEEN_PLAYER 1,0,0,0
  prodjlink.py nfs PLAYER_IP PATH OUT [OFFSET LEN] [--sd]   read a file from a player's USB (/C/) or SD (/B/), NFSv2
  (NfsClient and parse_abs_position are ports of alphatheta-connect, MIT -- see their docstrings)
"""
import json
import os
import select
import socket
import struct
import sys
import threading
import time

MAGIC = b'Qspt1WmJOL'
P_ANN, P_BEAT, P_STAT, P_DECKCMD, P_DECKLOG = 50000, 50001, 50002, 50098, 50099
SLOTS = {'none': 0, 'cd': 1, 'sd': 2, 'usb': 3, 'collection': 4}
SLOT_NAME = {v: k for k, v in SLOTS.items()}
TTYPES = {'rekordbox': 1, 'unanalyzed': 2, 'cd': 5}
PLAY_MODE = {0: 'no_track', 2: 'loading', 3: 'playing', 4: 'looping', 5: 'paused', 6: 'cued', 7: 'cuing',
             8: 'platter_held', 9: 'searching', 0x0e: 'spun_down', 0x11: 'ended'}
F_PLAYING, F_MASTER, F_SYNC, F_ONAIR, F_BPMSYNC = 0x40, 0x20, 0x10, 0x08, 0x02
KIND = {'cdj': (1, 1, 0), 'mixer': (2, 3, 0x31), 'rekordbox': (1, 3, 0)}   # keepalive 0x25, 0x34, 0x35 (mixer = real A9)


# ---------------------------------------------------------------------------------------------- frames / checksums
def csum(d):
    if len(d) & 1:
        d += b'\0'
    s = sum(struct.unpack('>%dH' % (len(d) // 2), d))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def udp_frame(dmac, smac, sip, dip, sp, dp, pay):
    ul = 8 + len(pay)
    udp = struct.pack('>HHHH', sp, dp, ul, 0) + pay
    c = csum(sip + dip + struct.pack('>BBH', 0, 17, ul) + udp) or 0xFFFF
    udp = udp[:6] + struct.pack('>H', c) + udp[8:]
    ip = struct.pack('>BBHHHBBH4s4s', 0x45, 0, 20 + ul, 0, 0, 64, 17, 0, sip, dip)
    ip = ip[:10] + struct.pack('>H', csum(ip)) + ip[12:]
    return dmac + smac + b'\x08\x00' + ip + udp


class McastSeg:
    """The emulator's L2 segment. recv() -> (src_ip, src_port, dst_port, payload) or None."""
    lan = False

    def __init__(self, group, my_ip='169.254.77.78', my_mac='02:00:00:00:77:78', bcast='169.254.255.255'):
        g, _, p = group.partition(':')
        self.dest = (g, int(p))
        self.ip, self.mac = socket.inet_aton(my_ip), bytes.fromhex(my_mac.replace(':', ''))
        self.bcast = bcast
        self.macs = {}                                   # ip bytes -> mac
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        s.bind(('', int(p)))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                     struct.pack('4s4s', socket.inet_aton(g), socket.inet_aton('0.0.0.0')))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        self.s = s
        self.lock = threading.Lock()

    def send(self, dst_ip, dport, pay, sport=None):
        dip = socket.inet_aton(dst_ip)
        dmac = self.macs.get(dip, b'\xff' * 6)
        f = udp_frame(dmac, self.mac, self.ip, dip, sport or dport, dport, pay)
        with self.lock:
            self.s.sendto(f, self.dest)

    def recv(self, timeout):
        if not select.select([self.s], [], [], timeout)[0]:
            return None
        f, _ = self.s.recvfrom(65535)
        if len(f) < 42 or f[6:12] == self.mac:
            return False
        if f[12:14] == b'\x08\x06':                      # ARP who-has me -> reply
            if struct.unpack('>H', f[20:22])[0] == 1 and f[38:42] == self.ip:
                arp = struct.pack('>HHBBH', 1, 0x0800, 6, 4, 2) + self.mac + self.ip + f[22:28] + f[28:32]
                with self.lock:
                    self.s.sendto(f[22:28] + self.mac + b'\x08\x06' + arp, self.dest)
            return False
        if f[12:14] != b'\x08\x00' or f[23] != 17:
            return False
        ihl = (f[14] & 15) * 4
        u = 14 + ihl
        sp, dp, ul = struct.unpack_from('>HHH', f, u)
        self.macs[f[26:30]] = f[6:12]
        return socket.inet_ntoa(f[26:30]), sp, dp, f[u + 8:u + ul]


class UdpNet:
    """The real LAN (the user's rig only). my_ip = this PC's address on the DJ Link subnet."""
    lan = True

    def __init__(self, my_ip, bcast='169.254.255.255', ports=(P_ANN, P_BEAT, P_STAT, 50004, P_DECKLOG)):
        self.my_ip, self.bcast = my_ip, bcast
        self.ip = socket.inet_aton(my_ip)
        self.mac = b'\0' * 6
        self.socks = {}
        for p in ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, 'SO_REUSEPORT'):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.bind(('', p))
            self.socks[p] = s
        self.tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def send(self, dst_ip, dport, pay, sport=None):
        s = self.socks.get(sport or dport, self.tx)
        s.sendto(pay, (dst_ip, dport))

    def recv(self, timeout):
        r = select.select(list(self.socks.values()), [], [], timeout)[0]
        if not r:
            return None
        s = r[0]
        d, a = s.recvfrom(65535)
        if a[0] == self.my_ip:
            return False
        return a[0], a[1], s.getsockname()[1], d


class A9Net:
    """The fake A9's own transport on the REAL LAN (explicit opt-in only, rig.py `allow_fake_a9_lan`): sockets bound
    to the A9's own link-local alias (e.g. `sudo ifconfig en4 alias 169.254.142.194 netmask 255.255.0.0`) on
    50000/50001/50002/50004, so everything it sends carries that source address and unicast to it lands here (BSD
    picks the exact-address socket over the rig's wildcard ones). A socket bound to a unicast address never sees
    broadcasts on macOS: those reach the rig's wildcard UdpNet, whose Link.taps call feed() to hand them over."""
    lan = True

    def __init__(self, my_ip, bcast='169.254.255.255', ports=(P_ANN, P_BEAT, P_STAT, 50004)):
        self.my_ip, self.bcast = my_ip, bcast
        self.ip = socket.inet_aton(my_ip)
        self.mac = b'\0' * 6
        self.socks = {}
        for p in ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, 'SO_REUSEPORT'):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
            s.bind((my_ip, p))
            self.socks[p] = s
        self.tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.tx.bind((my_ip, 0))
        self.q = []
        self.qlock = threading.Lock()

    def feed(self, src, sp, dp, d):
        """Link.taps hook: broadcasts the rig's wildcard sockets got (never our own)."""
        if src != self.my_ip and dp in (P_ANN, P_BEAT, P_STAT, 50004):
            with self.qlock:
                self.q.append((src, sp, dp, d))
                del self.q[:-2000]

    def send(self, dst_ip, dport, pay, sport=None):
        s = self.socks.get(sport or dport, self.tx)
        try:
            s.sendto(pay, (dst_ip, dport))
        except OSError:
            if s is not self.tx:
                self.tx.sendto(pay, (dst_ip, dport))

    def recv(self, timeout):
        with self.qlock:
            if self.q:
                return self.q.pop(0)
        r = select.select(list(self.socks.values()), [], [], timeout)[0]
        if not r:
            return None
        d, a = r[0].recvfrom(65535)
        if a[0] == self.my_ip:
            return False
        return a[0], a[1], r[0].getsockname()[1], d

    def close(self):
        for s in list(self.socks.values()) + [self.tx]:
            try:
                s.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------------------------- packet builders
def name20(name):
    return name.encode()[:20].ljust(20, b'\0')


def hdr(ptype, name, dev, body, sub=0):
    """50001/50002 layout: magic, type @0x0a, name @0x0b, 0x01 @0x1f, subtype @0x20, device @0x21, len @0x22."""
    return MAGIC + bytes([ptype]) + name20(name) + bytes([1, sub, dev]) + struct.pack('>H', len(body)) + body


def keepalive(name, dev, kind, mac, ip, peers=1):
    b25, b34, b35 = KIND[kind]
    p = bytearray(0x36)
    p[:10] = MAGIC
    p[0x0a] = 0x06
    p[0x0c:0x20] = name20(name)
    p[0x20], p[0x21] = 1, 2
    p[0x22:0x24] = struct.pack('>H', 0x36)
    p[0x24], p[0x25] = dev, b25
    p[0x26:0x2c] = mac
    p[0x2c:0x30] = ip
    p[0x30], p[0x34], p[0x35] = peers, b34, b35
    return bytes(p)


def pkt_fader(name, dev, cmds):
    """cmds {player 1..4: 'start'|'stop'} -> C1..C4 (0 start, 1 stop+cue, 2 unchanged)."""
    c = [2, 2, 2, 2]
    for pl, what in cmds.items():
        if 1 <= int(pl) <= 4:
            c[int(pl) - 1] = {'start': 0, 'stop': 1, 'none': 2}[what]
    return hdr(0x02, name, dev, bytes(c))


def pkt_load(name, dev, src_player, slot, rbid, ttype=1, target=None, b40=0x32):
    body = bytearray(0x34)
    body[0x00] = dev                       # 0x24
    body[0x04] = src_player                # 0x28
    body[0x05] = slot                      # 0x29
    body[0x06] = ttype                     # 0x2a
    body[0x08:0x0c] = struct.pack('>I', rbid)   # 0x2c
    if b40 is not None:
        body[0x40 - 0x24] = b40            # beat-link LOAD_TRACK_PAYLOAD constant
    if target is not None:
        body[0x41 - 0x24] = target - 1     # CDJ-3000s read the destination here (harmless on NXS2)
    return hdr(0x19, name, dev, bytes(body))


def pkt_sync(name, dev, cmd):
    return hdr(0x2a, name, dev, struct.pack('>II', dev, cmd))


def pkt_onair(name, dev, flags, six=True):
    """Channels on-air, type 0x03 on 50001. six=True: the DJM-A9's own form (real captures re/captures/*.pcap:
    53 bytes, subtype 0x03, len 0x11, ch1..4 @0x24..0x27, ch5/6 @0x2d/0x2e as beat-link reads 6-channel
    mixers -- the A9 has 4 channels, so those stay 0). six=False: the classic 4-channel form (len 9, 45 bytes)."""
    f = [1 if x else 0 for x in (list(flags) + [0] * 6)[:6]]
    if not six:
        return hdr(0x03, name, dev, bytes(f[:4]) + b'\0' * 5)
    body = bytearray(0x11)
    body[0:4] = bytes(f[:4])
    body[9], body[10] = f[4], f[5]
    return hdr(0x03, name, dev, bytes(body), sub=0x03)


# ---------------------------------------------------------------------------------------------- parsers
def u16(d, o):
    return struct.unpack_from('>H', d, o)[0]


def u32(d, o):
    return struct.unpack_from('>I', d, o)[0]


def pitch_pct(raw):
    return round((raw - 0x100000) * 100.0 / 0x100000, 2)


def dev_name(d, o=0x0b):
    return d[o:o + 20].split(b'\0')[0].decode('ascii', 'replace')


def parse_keepalive(d):
    if len(d) < 0x30 or d[0x0a] != 0x06:
        return None
    return dict(name=dev_name(d, 0x0c), dev=d[0x24], mac=d[0x26:0x2c].hex(':'),
                ip=socket.inet_ntoa(d[0x2c:0x30]), peers=d[0x30] if len(d) > 0x30 else None,
                dtype=d[0x34] if len(d) > 0x34 else None)


def parse_cdj_status(d):
    """type 0x0a. NXS2 = 0x124 bytes; CDJ-3000 longer (0x200 / 0x480 seen) with the same core offsets."""
    if len(d) < 0xd0 or d[0x0a] != 0x0a:
        return None
    bpm = u16(d, 0x92)
    fl = d[0x89]
    pm = d[0x7b]
    st = dict(kind='cdj', name=dev_name(d), dev=d[0x21], len=len(d),
              model='3000' if len(d) > 0x124 or '3000' in dev_name(d) else 'nxs2',
              activity=d[0x27], src_player=d[0x28], slot=d[0x29], slot_name=SLOT_NAME.get(d[0x29], d[0x29]),
              ttype=d[0x2a], rbid=u32(d, 0x2c), track_no=u16(d, 0x32),
              play_mode=pm, play_mode_name=PLAY_MODE.get(pm, hex(pm)), fw=d[0x7c:0x80].decode('ascii', 'replace'),
              flags=fl, playing=bool(fl & F_PLAYING), master=bool(fl & F_MASTER), synced=bool(fl & F_SYNC),
              onair=bool(fl & F_ONAIR), play2=d[0x8b], pitch=pitch_pct(u32(d, 0x8c)),
              bpm=None if bpm == 0xFFFF else bpm / 100.0, master_mm=d[0x9e], handoff=d[0x9f],
              beat=u32(d, 0xa0), beat_in_bar=d[0xa6], counter=u32(d, 0xc8))
    st['loaded'] = pm not in (0, 2) and st['rbid'] != 0
    return st


def parse_mixer_status(d):
    """type 0x29 (0x38 bytes): flags @0x27 (same bits as CDJ 0x89), pitch @0x28, BPM @0x2e, handoff @0x36,
    beat-in-bar @0x37. A9 level/meter fields: unknown (see Link.unknown)."""
    if len(d) < 0x38 or d[0x0a] != 0x29:
        return None
    fl, bpm = d[0x27], u16(d, 0x2e)
    return dict(kind='mixer', name=dev_name(d), dev=d[0x21], len=len(d), flags=fl, master=bool(fl & F_MASTER),
                synced=bool(fl & F_SYNC), playing=bool(fl & F_PLAYING), pitch=pitch_pct(u32(d, 0x28)),
                bpm=None if bpm == 0xFFFF else bpm / 100.0, handoff=d[0x36], beat_in_bar=d[0x37])


def parse_beat(d):
    if len(d) < 0x5d or d[0x0a] != 0x28:
        return None
    return dict(dev=d[0x21], next_beat_ms=u32(d, 0x24), next_bar_ms=u32(d, 0x2c), pitch=pitch_pct(u32(d, 0x54)),
                bpm=u16(d, 0x5a) / 100.0, beat_in_bar=d[0x5c])


def parse_abs_position(d):
    """CDJ-3000 absolute position, type 0x0b on 50001, ~30 ms (60 B). Layout from alphatheta-connect
    (MIT, chrisle; src/status/utils.ts:132-170, docs/ABSOLUTE_POSITION.md:21-32 after dysentery):
    0x21 dev, 0x24 track length s (u32), 0x28 playhead ms (u32), 0x2c pitch*6400 (s32), 0x30 BPM*10 (u32,
    0xffffffff unknown). Upstream does not check the type byte; we do (0x0b). NXS2 never sends it."""
    if len(d) < 0x34 or d[0x0a] != 0x0b or d[0x20] != 0x00 or u16(d, 0x22) < 0x0c:
        return None
    bpm = u32(d, 0x30)
    return dict(dev=d[0x21], track_len_s=u32(d, 0x24), playhead_ms=u32(d, 0x28),
                pitch=struct.unpack_from('>i', d, 0x2c)[0] / 6400.0, bpm=None if bpm == 0xFFFFFFFF else bpm / 10.0)


# ---------------------------------------------------------------------------------------------- the virtual device
class Link:
    """A virtual Pro DJ Link device + observer. on_event(kind, dict) gets every interesting event."""
    CHANGE_KEYS = ('rbid', 'src_player', 'slot', 'play_mode', 'playing', 'master', 'synced', 'onair', 'bpm', 'pitch',
                   'handoff')

    def __init__(self, net, number=5, name='rig', kind='cdj', on_event=None, announce=True):
        self.net, self.number, self.name, self.kind = net, number, name, kind
        self.on_event = on_event or (lambda k, e: None)
        self.devices, self.status, self.beats = {}, {}, {}
        self.positions = {}                          # dev -> latest CDJ-3000 absolute position (0x0b)
        self.onair_flags = None
        self.acks = []
        self.deck_records = []                       # (time, src, 128-byte record) from port 50099
        self.unknown = {}                            # (port, type, len, src) -> {'n', 'first', 'var' set}
        self.counts = {}
        self.taps = []                               # f(src, sport, dport, data) on every datagram (stagehand.py)
        self.cond = threading.Condition()
        self.run_ = True
        self.announce = announce
        self.rx = threading.Thread(target=self._rx, daemon=True)
        self.tx = threading.Thread(target=self._tx, daemon=True)

    def start(self):
        self.rx.start()
        self.tx.start()
        return self

    def stop(self):
        self.run_ = False

    # ---- loops
    def _tx(self):
        while self.run_:
            if self.announce:
                self.net.send(self.net.bcast, P_ANN,
                              keepalive(self.name, self.number, self.kind, self.net.mac, self.net.ip))
            time.sleep(1.5)

    def _rx(self):
        while self.run_:
            try:
                r = self.net.recv(0.2)
            except OSError:
                continue
            if not r:
                continue
            src, sp, dp, d = r
            for f in self.taps:
                try:
                    f(src, sp, dp, d)
                except Exception as e:
                    self.on_event('rx_error', dict(src=src, port=dp, err='tap %r' % e))
            try:
                self._handle(src, sp, dp, d)
            except Exception as e:  # never kill the receiver on one odd packet
                self.on_event('rx_error', dict(src=src, port=dp, err=repr(e), hex=d[:64].hex()))

    def _handle(self, src, sp, dp, d):
        now = time.time()
        if dp == P_DECKLOG and len(d) == 128:
            with self.cond:
                self.deck_records.append((time.monotonic(), src, d))
                del self.deck_records[:-4000]
                self.cond.notify_all()
            return
        if d[:10] != MAGIC or len(d) < 0x0b:
            return
        t = d[0x0a]
        self.counts[(dp, t)] = self.counts.get((dp, t), 0) + 1
        ev = None
        with self.cond:
            if dp == P_ANN and t == 0x06:
                k = parse_keepalive(d)
                if k:
                    new = k['dev'] not in self.devices
                    k['last'] = now
                    self.devices[k['dev']] = k
                    if new:
                        ev = ('device', k)
            elif dp == P_STAT and t == 0x0a:
                s = parse_cdj_status(d)
                s['ip'], s['t'] = src, now
                old = self.status.get(s['dev'])
                self.status[s['dev']] = s
                if old is None or any(old.get(x) != s.get(x) for x in self.CHANGE_KEYS):
                    ev = ('status', {x: s[x] for x in ('dev', 'name', 'model') + self.CHANGE_KEYS + ('play_mode_name',
                                                                                                   'loaded', 'fw')})
            elif dp == P_STAT and t == 0x29:
                s = parse_mixer_status(d)
                s['ip'], s['t'] = src, now
                old = self.status.get(s['dev'])
                self.status[s['dev']] = s
                if old is None or any(old.get(x) != s.get(x) for x in ('master', 'synced', 'bpm', 'handoff')):
                    ev = ('mixer_status', s)
                self._catalog(dp, d, src)            # mixer packets: keep the byte variance too (meters hunt)
            elif dp == P_BEAT and t == 0x28:
                b = parse_beat(d)
                if b:
                    b['t'] = now
                    self.beats[b['dev']] = b
            elif dp == P_BEAT and t == 0x0b and parse_abs_position(d):
                p = parse_abs_position(d)
                p['t'] = now
                self.positions[p['dev']] = p
            elif dp == P_BEAT and t == 0x03:
                f = list(d[0x24:0x28])
                if u16(d, 0x22) >= 0x11 and len(d) > 0x2e:
                    f += [d[0x2d], d[0x2e]]
                if f != self.onair_flags:
                    ev = ('onair', dict(dev=d[0x21], flags=f))
                self.onair_flags = f
            elif dp == P_BEAT and t in (0x26, 0x27):   # master handoff request / response
                ev = ('handoff', dict(src=src, type=t, dev=d[0x21], body=d[0x24:].hex()))
            elif t in (0x1a,):                      # load-track ack
                self.acks.append((now, src, t, d[0x1f:].hex()))
                ev = ('ack', dict(src=src, type=t, dev=d[0x21], body=d[0x1f:].hex()))
            elif dp == P_ANN and t in (0x0a, 0x00, 0x02, 0x04, 0x05, 0x08):
                pass                                 # number negotiation: ignore
            else:
                self._catalog(dp, d, src)
            self.cond.notify_all()
        if ev:
            self.on_event(*ev)

    def _catalog(self, dp, d, src):
        k = (dp, d[0x0a], len(d), src)
        u = self.unknown.get(k)
        if u is None:
            self.unknown[k] = u = dict(n=0, first=d, var=set())
            self.on_event('new_packet_kind', dict(port=dp, type=d[0x0a], len=len(d), src=src, hex=d.hex()))
        u['n'] += 1
        f = u['first']
        u['var'].update(i for i in range(min(len(f), len(d))) if f[i] != d[i])

    # ---- queries
    def ip_of(self, dev):
        k = self.devices.get(dev) or self.status.get(dev)
        return k and k['ip']

    def wait(self, pred, timeout):
        end = time.monotonic() + timeout        # monotonic: the WSL wall clock jumps by seconds
        with self.cond:
            while True:
                r = pred()
                if r:
                    return r
                left = end - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(min(left, 0.25))

    def wait_device(self, dev, timeout=30):
        return self.wait(lambda: self.devices.get(dev), timeout)

    # ---- commands
    def _target(self, dev):
        ip = self.ip_of(dev)
        if not ip:
            raise RuntimeError('device %s not seen on the network' % dev)
        return ip

    def fader_start(self, target, cmds, broadcast=False):
        """target: a player number (unicast) or None+broadcast. cmds {player: 'start'|'stop'}"""
        p = pkt_fader(self.name, self.number, cmds)
        self.net.send(self.net.bcast if broadcast or target is None else self._target(target), P_BEAT, p)
        return p

    def load_track(self, target, src_player, slot, rbid, ttype=1, **kw):
        p = pkt_load(self.name, self.number, src_player, SLOTS.get(slot, slot) if isinstance(slot, str) else slot,
                     rbid, ttype, target=target, **kw)
        self.net.send(self._target(target), P_STAT, p)
        return p

    def sync(self, target, on=True):
        p = pkt_sync(self.name, self.number, 0x10 if on else 0x20)
        self.net.send(self._target(target), P_BEAT, p)
        return p

    def become_master(self, target):
        p = pkt_sync(self.name, self.number, 0x01)
        self.net.send(self._target(target), P_BEAT, p)
        return p

    def on_air(self, flags):
        p = pkt_onair(self.name, self.number, flags)
        self.net.send(self.net.bcast, P_BEAT, p)
        return p

    def unknown_report(self):
        out = []
        for (port, t, ln, src), u in sorted(self.unknown.items()):
            out.append(dict(port=port, type=t, len=ln, src=src, n=u['n'], varying=sorted(u['var']),
                            first=u['first'].hex()))
        return out


# ---------------------------------------------------------------------------------------------- fake DJM-A9
def ann_hdr(ptype, name, body, sub=2):
    """50000 layout: magic, type @0x0a, 0x00 @0x0b, name @0x0c, 0x01 @0x20, sub @0x21, total length @0x22."""
    p = MAGIC + bytes([ptype, 0]) + name20(name) + bytes([1, sub])
    return p + struct.pack('>H', len(p) + 2 + len(body)) + body


class AudioRec:
    """What the fake A9 hears on 50004: the decks' 0x1e Touch Audio packets (main_touchaudio.s send_audio):
    I flag @0x24 (1 = engage request, zero PCM), C big-endian @0x28, PCM @0x2c: 0x540 bytes = 336 s16 LE stereo
    frames at 48 kHz (one packet per 7 ms timing packet). Per source ip: counts, C gaps/dups, arrival gaps,
    peak/RMS of the PCM; optional raw dump (pcm_dir) for an offline comparison with the track."""
    GAP = 0.015

    def __init__(self, on_event=None, pcm_dir=None):
        self.on_event = on_event or (lambda k, e: None)
        self.pcm_dir = pcm_dir
        self.lock = threading.Lock()
        self.src = {}
        self.mark = 0

    def reset(self, tag=None):
        with self.lock:
            for st in self.src.values():
                if st.get('f'):
                    st['f'].close()
            self.src = {}
            self.mark += 1
            self.tag = tag

    def quiet(self, ip):
        st = self.src.get(ip)
        return time.monotonic() - st['last'] if st else 99

    def rx(self, src, d):
        now = time.monotonic()
        body = d[0x2c:0x2c + 0x540]
        i_flag = d[0x24] if len(d) > 0x24 else 0
        c = struct.unpack_from('>I', d, 0x28)[0] if len(d) >= 0x2c else 0
        with self.lock:
            st = self.src.get(src)
            if st is None:
                st = self.src[src] = dict(n=0, pcm=0, zero=0, i1=0, cgap=0, cdup=0, gaps=[], first=now, last=now,
                                          first_pcm=None, last_pcm=None, peak=0, sq=0.0, ns=0, lens={}, f=None,
                                          c=None, peaks=[], bursts=[[now, now, 0]])
                if self.pcm_dir:
                    os.makedirs(self.pcm_dir, exist_ok=True)
                    st['f'] = open(os.path.join(self.pcm_dir, 'a9_%s_%s_%d.pcm' % (getattr(self, 'tag', None) or 'run',
                                                                               src, self.mark)), 'wb')
            dt = now - st['last']
            if st['n'] and dt > self.GAP:
                st['gaps'].append((round(now - st['first'], 3), round(dt * 1000, 1)))
            if st['n'] and dt > 0.5:
                st['bursts'].append([now, now, 0])
            st['bursts'][-1][1] = now
            st['bursts'][-1][2] += 1
            st['last'] = now
            st['n'] += 1
            st['lens'][len(d)] = st['lens'].get(len(d), 0) + 1
            if st['c'] is not None:
                if c == st['c']:
                    st['cdup'] += 1
                elif c != (st['c'] + 1) & 0xFFFFFFFF:
                    st['cgap'] += 1
            st['c'] = c
            if i_flag:
                st['i1'] += 1
            n = len(body) // 2
            smp = struct.unpack('<%dh' % n, body[:n * 2]) if n else ()
            pk = max(max(smp), -min(smp)) if smp else 0
            if pk == 0:
                st['zero'] += 1
            else:
                st['pcm'] += 1
                if st['first_pcm'] is None:
                    st['first_pcm'] = now
                st['last_pcm'] = now
                st['peak'] = max(st['peak'], pk)
                st['sq'] += sum(x * x for x in smp)
                st['ns'] += n
            st['peaks'].append(pk)
            del st['peaks'][:-20000]
            if st['f']:
                st['f'].write(body)

    def stats(self, ip=None, since=None):
        out = {}
        with self.lock:
            for src, st in self.src.items():
                if ip and src != ip:
                    continue
                span = st['last'] - st['first']
                pspan = (st['last_pcm'] - st['first_pcm']) if st['first_pcm'] else 0
                out[src] = dict(n=st['n'], pcm=st['pcm'], zero=st['zero'], i1=st['i1'], c_gaps=st['cgap'],
                                c_dups=st['cdup'], span_s=round(span, 2),
                                rate=round((st['n'] - 1) / span, 1) if span > 0 else 0,
                                pcm_span_s=round(pspan, 2), pcm_rate=round((st['pcm'] - 1) / pspan, 1) if pspan > 0 else 0,
                                gaps_n=len(st['gaps']), gap_max_ms=max([g[1] for g in st['gaps']] or [0]),
                                gaps=st['gaps'][:20], peak=st['peak'],
                                rms=round((st['sq'] / st['ns']) ** 0.5, 1) if st['ns'] else 0,
                                lens=st['lens'], quiet_s=round(time.monotonic() - st['last'], 2),
                                bursts=[(round(b[1] - b[0], 2), b[2]) for b in st['bursts']])
        return out


class FakeA9(threading.Thread):
    """A DJM-A9 (fw 1.22 class) rebuilt from the real one's captures (re/captures/0[0-3]-*.pcap, 12-10-2026, and
    re/LINK_CUE.md 'RESUELTO' for the Touch Audio part). Faithful bits, all measured on the real mixer:
      - power-on: claims 0x00 x3 (k=1..3, 0x25=03, MAC), 0x02 x3 (IP, MAC, 0x21, k, 03 01), 0x04 x3 (0x21, k),
        ~0.275-0.3 s apart, broadcast 50000 from port 50000;
      - keepalive 0x06, 54 B, every 2.0 s: 0x24=0x21 0x25=0x02 MAC IP 0x30=peers 0x34=0x03 0x35=0x31;
      - on-air 0x03 on 50001 every 0.3 s, 53 B, subtype 0x03, len 0x11, from an ephemeral source port that
        increments by one per packet (1291.., 5096..); content fixed while the faders do not move;
      - a joining device's claim 0x02 -> 0x05 x3 unicast (0x21, k=1..3, 0.3 s apart), then six 0x04 packets
        on 50001 (100 B, 0x24 = 0x14,0x24..0x64, 0x25 = 0x21) at once;
      - Touch Audio on 50004: a 0x1e engage from a device number the A9 has registered (17 = where rekordbox was
        registered; 18 also worked) -> timing 0x20 unicast every 7 ms (C +1, E = LINK CUE switch, T = elected);
        from any other number -> handover 0x1f (36 B, len 0) per engage packet. A 0x29 status from a device
        -> 0x30 (36 B, subtype 0x03); its 0x31 reply makes the device eligible too (the rekordbox path).
    NOT seen from the real A9 (so off by default): a 0x29 mixer status on 50002 (beat-link layout available with
    status29=True), any channel level / meter / fader-position packet. Unknown: whether timing stops when the
    elected device goes quiet (we keep streaming, as our deck's 1-s election timeout expects).
    mode 'auto' = the behaviour above; 'manual' = the orchestrator's: timing to fixed targets with forced E/T."""
    NAME, NUM = 'DJM-A9', 0x21

    def __init__(self, net, mode='auto', linkcue=1, ta_slots=(17, 18), onair=(0, 1, 1, 1), boot_claim=True,
                 status29=False, on_event=None):
        super().__init__(daemon=True)
        self.net, self.mode, self.linkcue = net, mode, linkcue
        self.ta_slots, self.onair, self.boot_claim, self.status29 = set(ta_slots), list(onair), boot_claim, status29
        self.on_event = on_event or (lambda k, e: None)
        self.ka = True              # powered: claims (once), keepalive, on-air
        self.tm = False             # timing stream on
        self.e, self.t = 0, 0       # E / T in the timing packets
        self.c = 1000
        self.targets = []           # manual mode: timing destinations (ip strings)
        self.elected = None         # auto mode: (dev, ip)
        self.eligible = set()
        self.peers = {}             # dev -> ip (keepalives seen)
        self.n_rx_1e = self.n_handover = self.n_timing = 0
        self.run_ = True
        self._q = []                # (due, port, dst, payload, sport)
        self._sport = 1291
        self._was_on = False
        self._answered = {}         # dev -> time of our 0x05 burst
        self._asked = {}            # dev -> time of our 0x30
        self.audio = AudioRec(on_event=self.on_event)

    # ---- packets
    def p_claim(self, ptype, k):
        mac, ip = self.net.mac, self.net.ip
        if ptype == 0x00:
            return ann_hdr(0x00, self.NAME, bytes([k, 3]) + mac)
        if ptype == 0x02:
            return ann_hdr(0x02, self.NAME, ip + mac + bytes([self.NUM, k, 3, 1]))
        return ann_hdr(ptype, self.NAME, bytes([self.NUM, k]))           # 0x04 / 0x05

    def p_keepalive(self):
        return keepalive(self.NAME, self.NUM, 'mixer', self.net.mac, self.net.ip, peers=1 + len(self.peers))

    def p_timing(self):
        return hdr(0x20, self.NAME, self.NUM, struct.pack('>IBB', self.c & 0xFFFFFFFF, self.e, self.t))

    def p_status29(self):
        b = bytearray(0x14)
        b[0] = self.NUM
        b[3] = 0xc0                                   # 0x27 flags (beat-link layout; unverified on the A9)
        b[4:8] = struct.pack('>I', 0x100000)          # 0x28 pitch 0 %
        b[8:10] = b'\x80\x00'
        b[10:12] = struct.pack('>H', 12000)           # 0x2e BPM
        b[0x12], b[0x13] = 0xff, 0                    # 0x36 handoff, 0x37 beat
        return hdr(0x29, self.NAME, self.NUM, bytes(b), sub=0)

    def later(self, dt, port, dst, pay, sport=None):
        self._q.append((time.monotonic() + dt, port, dst, pay, sport))

    def set_elect(self, e, t):
        self.e, self.t = e, t

    # ---- loop
    def run(self):
        now = time.monotonic()
        nka = non = n29 = nt = now
        while self.run_:
            now = time.monotonic()
            if self.ka and not self._was_on and self.boot_claim:
                for i, (ty, k) in enumerate([(0, 1), (0, 2), (0, 3), (2, 1), (2, 2), (2, 3), (4, 1), (4, 2), (4, 3)]):
                    self.later(0.29 * i, P_ANN, self.net.bcast, self.p_claim(ty, k), P_ANN)
                nka = non = n29 = now + 0.29 * 9
            self._was_on = self.ka
            if self.ka:
                if now >= nka:
                    self.net.send(self.net.bcast, P_ANN, self.p_keepalive(), P_ANN)
                    nka = now + 2.0
                if now >= non:
                    self.net.send(self.net.bcast, P_BEAT, pkt_onair(self.NAME, self.NUM, self.onair), self._sport)
                    self._sport = 1024 + (self._sport - 1023) % 64000
                    non = now + 0.3
                if self.status29 and now >= n29:
                    self.net.send(self.net.bcast, P_STAT, self.p_status29(), P_STAT)
                    n29 = now + 0.2
            due = [x for x in self._q if x[0] <= now]
            if due:
                self._q = [x for x in self._q if x[0] > now]
                for _, port, dst, pay, sp in due:
                    self.net.send(dst, port, pay, sp)
            if self.tm and now >= nt:
                dsts = self.targets if self.mode == 'manual' else ([self.elected[1]] if self.elected else [])
                pay = self.p_timing()
                for ip in dsts:
                    self.net.send(ip, 50004, pay, 50004)
                self.c += 1
                self.n_timing += 1
                nt += 336 / 48000.0                          # 7.0 ms
                if now - nt > 0.1:
                    nt = now
            try:
                r = self.net.recv(0.001)
            except OSError:
                r = None
            if r:
                self._handle(*r)

    def _handle(self, src, sp, dp, d):
        if d[:10] != MAGIC or len(d) < 0x24:
            return
        t = d[0x0a]
        if dp == P_ANN and t == 0x06 and len(d) > 0x24 and d[0x24] != self.NUM:
            self.peers[d[0x24]] = src
        elif dp == P_ANN and t == 0x02 and len(d) >= 0x30 and self.ka:
            dev = d[0x2e]
            if time.monotonic() - self._answered.get(dev, -99) > 10:          # one burst per join
                self._answered[dev] = time.monotonic()
                for k in (1, 2, 3):
                    self.later(0.9 + 0.3 * (k - 1), P_ANN, src, self.p_claim(0x05, k), P_ANN)
                for i in range(6):
                    body = bytes([0x14 + 0x10 * i, self.NUM]) + b'\0' * 0x3e
                    self.later(1.8, P_BEAT, self.net.bcast, hdr(0x04, self.NAME, self.NUM, body), 0)
                self.on_event('a9_join', dict(dev=dev, ip=src))
        elif dp == P_STAT and t == 0x29 and d[0x21] != self.NUM:
            if time.monotonic() - self._asked.get(d[0x21], -99) > 2:
                self._asked[d[0x21]] = time.monotonic()
                self.net.send(src, P_STAT, hdr(0x30, self.NAME, self.NUM, b'', sub=0x03), P_STAT)
        elif dp == P_STAT and t == 0x31:
            self.eligible.add(d[0x21])
            self.on_event('a9_eligible', dict(dev=d[0x21], ip=src))
        elif dp == 50004 and t == 0x1e:
            self.n_rx_1e += 1
            dev = d[0x21]
            self.audio.rx(src, d)
            if self.mode != 'auto':
                return
            if dev in self.ta_slots or dev in self.eligible:
                # a new source (another deck can use the same device 17) takes over with an engage request (I=1)
                # once the elected one has been quiet for 0.5 s
                quiet = self.audio.quiet(self.elected[1]) if self.elected else 99
                if not self.elected or (self.elected != (dev, src) and len(d) > 0x24 and d[0x24] and quiet > 0.5):
                    self.elected = (dev, src)
                    self.e, self.t, self.tm = self.linkcue, dev, True
                    self.on_event('a9_elect', dict(dev=dev, ip=src, E=self.e))
            else:
                self.n_handover += 1
                self.net.send(src, 50004, hdr(0x1f, self.NAME, self.NUM, b''), 50004)

    def set_linkcue(self, on):
        self.linkcue = 1 if on else 0
        if self.mode == 'auto' and self.elected:
            self.e = self.linkcue



# ---------------------------------------------------------------------------------------------- NFS (read-only)
class NfsClient:
    """Read files from a player's USB/SD over its NFSv2 server (UDP ONC-RPC), e.g. another deck's ANLZ.

    Port of alphatheta-connect's src/nfs (MIT; Copyright (c) 2013 Evan Purkhiser, prolink-connect; fork by
    chrisle): portmap 100000 v2 GETPORT (proc 3, proto 17) on 111 (rekordbox: 50111) (nfs/index.ts:114-122,
    programs.ts:32-60); mount 100005 v1 EXPORT (5) / MNT (1) (xdr.ts:235-273); nfs 100003 v2 LOOKUP (4) /
    READ (6), 32-byte handles, READ <= 8192 B (xdr.ts:275-358, programs.ts:11,262-311). AUTH_UNIX with the
    CDJ's stamp 0x967b8703, empty machine name, uid/gid 0 (rpc.ts:12-24,69-98). Paths and export names are
    UTF-16LE strings written WITHOUT XDR padding (xdr.ts:61-81) -- copied as is, it works on real players.
    Mounts: USB '/C/', SD '/B/' (nfs/index.ts:36-39). Database paths are tried as '.PIONEER/...' then
    'PIONEER/...' on non-Windows hosts (localdb/index.ts:303-333). ANLZ = <track analyze path>.DAT/.EXT/.2EX
    (localdb/rekordbox/index.ts:59). Read-only: no write/create procedure exists here.
    """
    STAMP = 0x967B8703

    def __init__(self, ip, portmap_port=111, timeout=2.0, retries=3, chunk=8192):
        self.ip, self.pm, self.timeout, self.retries = ip, portmap_port, timeout, retries
        self.chunk = min(chunk, 8192)                    # 8192 = protocol max (programs.ts:11); needs IP fragmentation
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.xid = random_xid()
        self.ports, self.roots = {}, {}

    def close(self):
        self.sock.close()

    @staticmethod
    def _u16le(s):
        b = s.encode('utf-16le')
        return struct.pack('>I', len(b)) + b

    def call(self, port, prog, vers, proc, args=b''):
        self.xid = (self.xid + 1) & 0xFFFFFFFF
        cred = struct.pack('>II', self.STAMP, 0) + struct.pack('>III', 0, 0, 0)     # stamp, name '', uid, gid, gids[]
        msg = (struct.pack('>IIIIII', self.xid, 0, 2, prog, vers, proc) + struct.pack('>II', 1, len(cred)) + cred +
               struct.pack('>II', 0, 0) + args)
        for _ in range(self.retries):
            self.sock.sendto(msg, (self.ip, port))
            end = time.monotonic() + self.timeout
            while time.monotonic() < end:
                r = select.select([self.sock], [], [], max(0, end - time.monotonic()))[0]
                if not r:
                    break
                d, _a = self.sock.recvfrom(65535)
                if len(d) < 24 or struct.unpack_from('>I', d)[0] != self.xid:
                    continue
                xid, mtype, rstat = struct.unpack_from('>III', d)
                if mtype != 1 or rstat != 0:
                    raise IOError('rpc denied (%d)' % rstat)
                vlen = struct.unpack_from('>I', d, 16)[0]
                o = 20 + vlen + (-vlen % 4)
                acc = struct.unpack_from('>I', d, o)[0]
                if acc != 0:
                    raise IOError('rpc accept_stat %d (prog %d proc %d)' % (acc, prog, proc))
                return d[o + 4:]
        raise TimeoutError('rpc timeout %s:%d prog %d proc %d' % (self.ip, port, prog, proc))

    def port(self, prog, vers):
        if prog not in self.ports:
            r = self.call(self.pm, 100000, 2, 3, struct.pack('>IIII', prog, vers, 17, 0))
            self.ports[prog] = struct.unpack_from('>I', r)[0]
        return self.ports[prog]

    def exports(self):
        r, o, out = self.call(self.port(100005, 1), 100005, 1, 5), 0, []
        while struct.unpack_from('>I', r, o)[0]:                  # ExportList option
            o += 4
            n = struct.unpack_from('>I', r, o)[0]
            out.append(r[o + 4:o + 4 + n].decode('utf-16le'))
            o += 4 + n + (-n % 4)
            while struct.unpack_from('>I', r, o)[0]:              # groups (ascii strings)
                n = struct.unpack_from('>I', r, o + 4)[0]
                o += 8 + n + (-n % 4)
            o += 4
        return out

    def root(self, mount='/C/'):
        if mount not in self.roots:
            r = self.call(self.port(100005, 1), 100005, 1, 1, self._u16le(mount))
            if struct.unpack_from('>I', r)[0] != 0:
                raise IOError('mount %s failed' % mount)
            self.roots[mount] = r[4:36]
        return self.roots[mount]

    def lookup(self, path, mount='/C/'):
        """-> (handle, size, type) of PATH (components separated by '/')."""
        h, size, ftype = self.root(mount), 0, 2
        for part in [p for p in path.lstrip('/').split('/') if p]:
            r = self.call(self.port(100003, 2), 100003, 2, 4, h + self._u16le(part))
            if struct.unpack_from('>I', r)[0] != 0:
                raise FileNotFoundError('%s (at %r)' % (path, part))
            h = r[4:36]
            ftype, size = struct.unpack_from('>I', r, 36)[0], struct.unpack_from('>I', r, 36 + 20)[0]
        return h, size, ftype

    def read(self, path, offset=0, length=None, mount='/C/'):
        h, size, _t = self.lookup(path, mount)
        length = size - offset if length is None else min(length, max(0, size - offset))
        out = bytearray()
        while len(out) < length:
            n = min(self.chunk, length - len(out))
            r = self.call(self.port(100003, 2), 100003, 2, 6, h + struct.pack('>III', offset + len(out), n, 0))
            if struct.unpack_from('>I', r)[0] != 0:
                raise IOError('read %s @%d failed' % (path, offset + len(out)))
            k = struct.unpack_from('>I', r, 4 + 68)[0]            # after status + fattr (17 words)
            if k == 0:
                break
            out += r[4 + 68 + 4:4 + 68 + 4 + k]
        return bytes(out)

    def read_db(self, name='export.pdb', mount='/C/'):
        for p in ('.PIONEER/rekordbox/' + name, 'PIONEER/rekordbox/' + name):
            try:
                return self.read(p, mount=mount)
            except FileNotFoundError:
                continue
        raise FileNotFoundError(name)


def random_xid():
    return struct.unpack('>I', os.urandom(4))[0]


def make_net(mcast=None, lan=None, bcast='169.254.255.255'):
    if mcast:
        return McastSeg(mcast, bcast=bcast)
    if lan:
        return UdpNet(lan, bcast=bcast)
    raise SystemExit('need --mcast G:P (emulator) or --lan MY_IP (real rig)')


def main(argv):
    mcast = lan = None
    bcast, number, kind = '169.254.255.255', 5, 'cdj'
    while argv and argv[0].startswith('--'):
        o = argv.pop(0)
        if o == '--mcast':
            mcast = argv.pop(0)
        elif o == '--lan':
            lan = argv.pop(0)
        elif o == '--bcast':
            bcast = argv.pop(0)
        elif o == '--number':
            number = int(argv.pop(0))
        elif o == '--kind':
            kind = argv.pop(0)
        else:
            sys.exit(__doc__)
    if not argv:
        sys.exit(__doc__)
    if argv[0] == 'nfs':                              # nfs IP PATH OUT [OFFSET LEN] [--sd]  (read-only)
        a = [x for x in argv[1:] if x != '--sd']
        c = NfsClient(a[0])
        data = c.read(a[1], int(a[3], 0) if len(a) > 3 else 0, int(a[4], 0) if len(a) > 4 else None,
                      mount='/B/' if '--sd' in argv else '/C/')
        open(a[2], 'wb').write(data)
        print('%d bytes -> %s' % (len(data), a[2]))
        return
    net = make_net(mcast, lan, bcast)
    link = Link(net, number, 'rig', kind,
                on_event=lambda k, e: print('%.3f %s %s' % (time.time(), k, json.dumps(e)), flush=True)).start()
    c, a = argv[0], argv[1:]
    if c == 'watch':
        time.sleep(float(a[0]) if a else 1e9)
        print(json.dumps(link.unknown_report(), indent=1))
        return
    tgt = int(a[0])
    if not link.wait_device(tgt, 10):
        sys.exit('player %d not seen' % tgt)
    time.sleep(0.5)
    if c == 'fader':
        link.fader_start(tgt, {tgt: a[1]})
    elif c == 'load':
        link.load_track(tgt, int(a[1]), SLOTS.get(a[2], None) or int(a[2]), int(a[3], 0),
                        int(a[4]) if len(a) > 4 else 1)
    elif c == 'sync':
        link.sync(tgt, a[1] == 'on')
    elif c == 'master':
        link.become_master(tgt)
    elif c == 'onair':
        link.on_air([int(x) for x in a[1].split(',')])
    time.sleep(3)


if __name__ == '__main__':
    main(sys.argv[1:])

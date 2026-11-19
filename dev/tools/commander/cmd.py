#!/usr/bin/env python3
"""cmd.py -- drive a TEST-build deck live over the Pro DJ Link cable (V4n26 network commander).

  cmd.py [opts] send "KEY INFO" "WAIT 2000" "TOUCH 28 235" ...   ops in atc.py's script syntax
  cmd.py [opts] mem 0x081F5010 32                                read MAIN RAM (1..64 bytes)
  cmd.py [opts] listen                                           print the deck's records (port 50099)
  cmd.py [opts] ver                                              the deck's build ID (+ its UPD from BUILDS.tsv)

The deck (TEST build, UTILITY TEST LOG = RED, normal boot) listens on UDP 50098 (mods/usblog cmd_poll,
polled from the TchAud task every 250 ms). Datagram: 'ATC1', u32 seq, u16 ops (<= 60), u16 byte sum of
the ops, then the ops in SCRIPT.BIN's 8-byte encoding (atc.py; op 8 = MEM b=len c=addr). The ops are
appended to the autotest's running script (or start one: no stick script needed). Answers come back in
the RED log stream (UDP broadcast 50099, 128-byte records):
  'V3CK' taken: w2 seq, w3 status (0 ok, 1 bad datagram, 2 no autotest, 3 op area full, 4 a USB
         script runs), w4 ops queued, w5 ops sent, w6 autotest state, w7 tail, w8 datagrams, w9 sender
  'V3CD' done:  w2 seq (the last ACK the executor passed: every op of that datagram ran), w3 step,
         w4 why, w5 state
  'V3MM' mem:   w2 seq, w3 addr, w4 len (0 = refused: only DRAM 0x08000000..0x18000000 and its
         0x8.. / 0xA.. mirrors), w5.. the bytes
Options:
  --ip A          deck IP or broadcast (default 169.254.255.255)
  --mcast G:P     emulator: inject raw Ethernet frames into QEMU's socket-mcast segment (and read the
                  records from it) instead of the host's network, e.g. 239.77.77.2:45002
  --done          send: wait for 'V3CD' of the last datagram too (default: only 'V3CK')
  --timeout S     seconds to wait for the answer (default 5; with --done 120)
ver (V4n36 trace): a MEM read of the build record at BLDID = 0x08014180 (ks layout: modsmenu block + 0x180;
mods/usblog/README.md): 'BLD1' + the ASCII build ID "TAG YYYYMMDD-HHMM HASH8" (build_final.sh), looked up in
BUILDS.tsv (build ID -> tag, UPD sha256; env CDJ_BUILDS, default ./BUILDS.tsv).
Docs: DEV_TOOLS.md (package root).
"""
import os
import select
import socket
import struct
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import atc  # noqa: E402

PORT_CMD, PORT_LOG = 50098, 50099
BLDID, BLD_LEN = int(os.environ.get('CDJ_BLDID', '0x08014180'), 0), 48   # build record (modsmenu bld_rec, ks layout;
#   a build without keyshift (stock layout): CDJ_BLDID=0x0813B180)
BUILDS = os.environ.get('CDJ_BUILDS', 'BUILDS.tsv')
MAX_OPS = 60
SRC_MAC = bytes.fromhex('020000007777')
SRC_IP = socket.inet_aton('169.254.77.77')


def encode(lines):
    """atc.py script lines -> list of 8-byte ops (no END)."""
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.write('\n'.join(lines) + '\n')
        p = f.name
    try:
        blob = atc.build(atc.parse(p))
    finally:
        os.unlink(p)
    n = struct.unpack_from('<H', blob, 4)[0] - 1          # minus atc's END
    return [blob[16 + 8 * i:24 + 8 * i] for i in range(n)]


def datagram(seq, ops):
    body = b''.join(ops)
    return b'ATC1' + struct.pack('<IHH', seq, len(ops), sum(body) & 0xFFFF) + body


def csum(d):
    if len(d) & 1:
        d += b'\0'
    s = sum(struct.unpack('>%dH' % (len(d) // 2), d))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def frame(dip, pay, sp=PORT_CMD, dp=PORT_CMD):
    ul = 8 + len(pay)
    udp = struct.pack('>HHHH', sp, dp, ul, 0) + pay
    c = csum(SRC_IP + dip + struct.pack('>BBH', 0, 17, ul) + udp) or 0xFFFF
    udp = udp[:6] + struct.pack('>H', c) + udp[8:]
    ip = struct.pack('>BBHHHBBH4s4s', 0x45, 0, 20 + ul, 0, 0, 64, 17, 0, SRC_IP, dip)
    ip = ip[:10] + struct.pack('>H', csum(ip)) + ip[12:]
    return b'\xff' * 6 + SRC_MAC + b'\x08\x00' + ip + udp


class Link:
    def __init__(self, ip, mcast):
        self.ip, self.mcast = ip, mcast
        if mcast:
            g, p = mcast.split(':')
            self.grp = (g, int(p))
            r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            r.bind(('', int(p)))
            r.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                         struct.pack('4s4s', socket.inet_aton(g), socket.inet_aton('0.0.0.0')))
            self.rx = r
            t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            t.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
            t.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
            self.tx = t
        else:
            r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except (AttributeError, OSError):
                pass
            r.bind(('', PORT_LOG))
            self.rx = r
            t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            t.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            self.tx = t

    def send(self, pay):
        if self.mcast:
            self.tx.sendto(frame(socket.inet_aton(self.ip), pay), self.grp)
        else:
            self.tx.sendto(pay, (self.ip, PORT_CMD))

    def records(self, until):
        """Yield (source ip, 128-byte record) until the deadline."""
        while True:
            left = until - time.time()
            if left <= 0:
                return
            if not select.select([self.rx], [], [], left)[0]:
                return
            d, a = self.rx.recvfrom(4096)
            if not self.mcast:
                if len(d) == 128:
                    yield a[0], d
                continue
            # raw Ethernet / IPv4 / UDP to PORT_LOG
            if len(d) < 42 or d[12:14] != b'\x08\x00' or d[23] != 17:
                continue
            ihl = (d[14] & 15) * 4
            u = 14 + ihl
            if struct.unpack_from('>H', d, u + 2)[0] != PORT_LOG:
                continue
            pay = d[u + 8:u + struct.unpack_from('>H', d, u + 4)[0]]
            if len(pay) == 128:
                yield socket.inet_ntoa(d[26:30]), pay


STATUS = {0: 'ok', 1: 'bad datagram', 2: 'no autotest', 3: 'op area full', 4: 'USB script runs'}


def show(src, d):
    tag, w = d[:4], struct.unpack('<32I', d)
    if tag == b'V3CK':
        return 'CK  seq %d %s: %d ops queued of %d, autotest state %d, tail %d, datagrams %d  (%s)' % (
            w[2], STATUS.get(w[3], w[3]), w[4], w[5], w[6] if w[6] != 0xFFFFFFFF else -1, w[7], w[8], src)
    if tag == b'V3CD':
        return 'CD  seq %d done: step %d why %d state %d  (%s)' % (w[2], w[3], w[4], w[5], src)
    if tag == b'V3MM':
        n = w[4]
        return 'MM  seq %d %#010x len %d%s  (%s)' % (w[2], w[3], n, ': ' + d[20:20 + n].hex(' ') if n
                                                    else ' REFUSED', src)
    return None


def ver_line(src, d):
    """A 'V3MM' answer of the build record -> 'BUILD <id>  UPD <tag> sha <sha16>' (BUILDS.tsv)."""
    n = struct.unpack_from('<I', d, 16)[0]
    raw = d[20:20 + n]
    if n < 8 or raw[:4] != b'BLD1':
        return 'ver: no build record at %#x (%s; a build before V4n36 trace?)  (%s)' % (
            BLDID, raw[:8].hex(' ') if n else 'REFUSED', src)
    bid = raw[4:].split(b'\0')[0].decode('latin1')
    upd = ''
    try:
        for line in open(BUILDS):
            f = line.rstrip('\n').split('\t')
            if f and f[0] == bid:
                upd = '  UPD %s sha256 %s' % (f[1] if len(f) > 1 else '?', f[2][:16] if len(f) > 2 else '?')
    except OSError:
        pass
    return 'BUILD %s%s  (%s)' % (bid, upd or '  (not in BUILDS.tsv)', src)


def main(argv):
    ip, mcast, done, timeout = '169.254.255.255', None, False, None
    while argv and argv[0].startswith('--'):
        o = argv.pop(0)
        if o == '--ip':
            ip = argv.pop(0)
        elif o == '--mcast':
            mcast = argv.pop(0)
        elif o == '--done':
            done = True
        elif o == '--timeout':
            timeout = float(argv.pop(0))
        else:
            sys.exit(__doc__)
    if not argv:
        sys.exit(__doc__)
    cmd, args = argv[0], argv[1:]
    link = Link(ip, mcast)
    if cmd == 'listen':
        for src, d in link.records(time.time() + (timeout or 1e9)):
            print(show(src, d) or '%s %s' % (src, d[:4]), flush=True)
        return
    if cmd == 'send':
        ops = encode(args)
    elif cmd == 'ver':
        ops = [struct.pack('<BBHI', 8, 0, BLD_LEN, BLDID)]
    elif cmd == 'mem':
        a, n = int(args[0], 0), int(args[1], 0)
        if not 1 <= n <= 64:
            sys.exit('mem: 1..64 bytes')
        ops = [struct.pack('<BBHI', 8, 0, n, a)]
    else:
        sys.exit(__doc__)
    seq0 = int(time.time() * 1000) & 0x7FFFFFFF or 1
    seqs = []
    for i in range(0, len(ops), MAX_OPS):
        seq = seq0 + len(seqs)
        link.send(datagram(seq, ops[i:i + MAX_OPS]))
        seqs.append(seq)
    want = {(b'V3CK', s) for s in seqs}
    if cmd in ('mem', 'ver'):
        want = {(b'V3MM', seqs[0])}
    if done and cmd == 'send':
        want.add((b'V3CD', seqs[-1]))
    end = time.time() + (timeout or (120 if done else 5))
    rc = 0
    for src, d in link.records(end):
        tag, seq = d[:4], struct.unpack_from('<I', d, 8)[0]
        if tag == b'V3CD':      # cumulative: a later seq done means ours ran too
            for s in seqs:
                if s <= seq:
                    want.discard((b'V3CD', s))
        if (tag, seq) in want or (tag == b'V3CD' and seq >= seqs[0] and seq in seqs):
            if cmd == 'ver' and tag == b'V3MM':
                print(ver_line(src, d), flush=True)
                want.discard((tag, seq))
                if not want:
                    return 0
                continue
            print(show(src, d), flush=True)
            if tag == b'V3CK' and struct.unpack_from('<I', d, 12)[0]:
                rc = 1
            want.discard((tag, seq))
        if not want:
            return rc
    print('cmd: no answer for %s' % ', '.join('%s %d' % (t.decode(), s) for t, s in sorted(want)), flush=True)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

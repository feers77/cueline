#!/usr/bin/env python3
"""rig.py -- run a declarative test plan across the rig: OUR deck (network commander, autotest/cmd.py protocol,
UDP 50098 -> records 50099), Pro DJ Link commands to a STOCK deck (prodjlink.py), a mixer (real DJM-A9 observed,
or the fake A9 on the emulator), waits and assertions on the statuses. Everything is logged to ONE JSONL
(timestamped) plus a short report.

  rig.py PLAN.yaml [--mcast G:P | --lan MY_IP] [--out DIR] [--set k=v ...] [--unattended] [--keep-going]

  --mcast G:P   emulator segment (raw frames into QEMU's socket-mcast group; nothing leaves the host)
  --lan MY_IP   real network (the user's rig): plain UDP from this PC's DJ Link address. Only there.
  The plan may carry `net: {mcast: ...}` / `net: {lan: ...}`; the command line wins.

Plan (YAML or a .py exposing PLAN = dict):
  name: ...
  vars: {ours: 3, stock: 2, deck_ip: 169.254.0.83}       # ${name} substitution in every string; --set overrides
  virtual: {number: 5, name: rig, kind: cdj}             # our Pro DJ Link identity (keepalive on 50000)
  steps:
   - {do: wait_device, player: ${stock}, timeout: 60}
   - {do: deck, ops: ["KEY USB", "WAIT 3000"], timeout: 60, done: true}     # our deck, atc.py script ops
   - {do: deck_mem, addr: 0x08000740, len: 8, as: version}                  # our deck RAM read (V3MM)
   - {do: load, target: ${stock}, src_player: ${ours}, slot: usb, rbid: ${ours_rbid}}
   - {do: fader, target: ${stock}, cmd: start|stop, broadcast: false}
   - {do: sync, target: N, enable: true} | {do: master, target: N}
   - {do: onair, flags: [1,1,0,0]}                       # as our virtual device (no real mixer on the net!)
   - {do: fake_a9, enable: true, mode: auto|manual, onair: [0,1,1,1], linkcue: 1}   # EMULATOR ONLY
   - {do: expect, player: N, timeout: 10, playing: true, master: true, rbid: 1, bpm: [127, 129],
      play_mode_name: [cued, paused], onair: true, loaded: true}           # list = one-of, [lo, hi] for numbers
   - {do: expect_ack, player: N, timeout: 3}             # load-track ack (type 0x1a)
   - {do: capture, player: N, field: rbid, as: ours_rbid}
   - {do: wait, s: 2}
   - {do: prompt, text: "move channel 2 fader up"}       # manual action; SKIP with --unattended
   - {do: shell, cmd: "..."}                             # e.g. an emulator screenshot
   - {do: stagehand, mixer: 169.254.142.194, timeout: 10} # join as Stagehand iPad (stagehand.py), read A9 0x39/0x58
   - {do: expect_vu, channel: 1, gt: 0.05, window: 0.5, timeout: 10, hold: 3}   # real audio on A9 ch1 (0..1 peak)
   - {do: expect_vu, channel: 2, lt: 0.01}                # silence
   - {do: expect_mixer, channel: 1, fader: [200, 255]}   # 0x39 fields: fader trim eq_hi eq_mid eq_low color_fx xf_assign
  Any step: `soft: true` (failure does not stop the plan), `name: ...`.
Output: DIR/rig.jsonl (every event) and DIR/report.txt; exit 1 if any hard step failed.
"""
import argparse
import importlib.util
import json
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import prodjlink as pdl  # noqa: E402
import stagehand as shd  # noqa: E402

CMD_PY = os.environ.get('CMD_PY') or next((p for p in (os.path.join(HERE, '..', 'commander', 'cmd.py'), os.path.expanduser('~/atc/cmd.py')) if os.path.exists(p)), '')


def load_cmd():
    spec = importlib.util.spec_from_file_location('atcmd', CMD_PY)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Log:
    def __init__(self, path):
        self.f = open(path, 'a')
        self.t0 = time.monotonic()

    def __call__(self, kind, **kw):
        e = dict(t=round(time.time(), 3), rel=round(time.monotonic() - self.t0, 3), kind=kind)
        e.update(kw)
        self.f.write(json.dumps(e, default=str) + '\n')
        self.f.flush()
        return e


class Deck:
    """Our deck's network commander over the same transport as the Link (one socket on the emulator)."""
    def __init__(self, link, ip, log):
        self.link, self.ip, self.log = link, ip, log
        self.c = load_cmd()
        self.seq = int(time.time() * 1000) & 0x7FFFFFFF or 1

    def _records(self, since):
        return [(t, s, d) for t, s, d in list(self.link.deck_records) if t >= since]

    def encode(self, lines):
        """atc ops; `TOUCH x y ms` with ms > 2000 (atc.py's cap; the autotest op takes ms as u16, AT_TEND = now + ms)
        is packed raw here: a held finger for the Link Cue preview tests."""
        ops, run = [], []
        for ln in lines:
            t = ln.split('#', 1)[0].split()
            if len(t) == 4 and t[0].upper() == 'TOUCH' and 2000 < int(t[3]) < 65536:
                if run:
                    ops += self.c.encode(run)
                    run = []
                ops.append(struct.pack('<BBHI', 3, 0, int(t[1]), int(t[2]) | int(t[3]) << 16))
            else:
                run.append(ln)
        if run:
            ops += self.c.encode(run)
        return ops

    def send(self, lines, done=True, timeout=60):
        ops = self.encode(lines)
        t_send = time.monotonic()
        seqs = []
        for i in range(0, len(ops), self.c.MAX_OPS):
            self.seq += 1
            self.link.net.send(self.ip, pdl.P_DECKCMD, self.c.datagram(self.seq, ops[i:i + self.c.MAX_OPS]),
                               pdl.P_DECKCMD)
            seqs.append(self.seq)
        want_ck, got = set(seqs), []
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for t, s, d in self._records(t_send):
                tag, seq = d[:4], struct.unpack_from('<I', d, 8)[0]
                if tag == b'V3CK' and seq in want_ck:
                    want_ck.discard(seq)
                    st = struct.unpack_from('<I', d, 12)[0]
                    got.append(self.c.show(s, d))
                    if st:
                        return False, got
                if tag == b'V3CD' and seq >= seqs[-1] and done and not want_ck:
                    got.append(self.c.show(s, d))
                    return True, got
            if not want_ck and not done:
                return True, got
            time.sleep(0.1)
        return False, got + ['timeout (waiting for %s)' % ('CK' if want_ck else 'CD')]

    def mem(self, addr, n, timeout=5):
        self.seq += 1
        t_send = time.monotonic()
        self.link.net.send(self.ip, pdl.P_DECKCMD, self.c.datagram(self.seq, [struct.pack('<BBHI', 8, 0, n, addr)]),
                           pdl.P_DECKCMD)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for t, s, d in self._records(t_send):
                if d[:4] == b'V3MM' and struct.unpack_from('<I', d, 8)[0] == self.seq:
                    ln = struct.unpack_from('<I', d, 16)[0]
                    return d[20:20 + ln] if ln else None
            time.sleep(0.05)
        return None


def subst(v, vars_):
    if isinstance(v, str):
        m = re.fullmatch(r'\$\{(\w+)\}', v)
        if m:
            return vars_[m.group(1)]
        return re.sub(r'\$\{(\w+)\}', lambda m: str(vars_[m.group(1)]), v)
    if isinstance(v, list):
        return [subst(x, vars_) for x in v]
    if isinstance(v, dict):
        return {k: subst(x, vars_) for k, x in v.items()}
    return v


def num(v):
    return int(v, 0) if isinstance(v, str) else v


def match(val, want):
    if isinstance(want, list):
        if len(want) == 2 and all(isinstance(x, (int, float)) for x in want) and isinstance(val, (int, float)) \
                and not isinstance(val, bool):
            return want[0] <= val <= want[1]
        return val in want
    return val == want


EXPECT_SKIP = ('do', 'player', 'timeout', 'soft', 'name', 'hold')


class Rig:
    def __init__(self, plan, args):
        self.plan, self.args = plan, args
        os.makedirs(args.out, exist_ok=True)
        self.log = Log(os.path.join(args.out, 'rig.jsonl'))
        self.vars = dict(plan.get('vars', {}))
        for kv in args.set or []:
            k, _, v = kv.partition('=')
            self.vars[k] = int(v) if re.fullmatch(r'-?\d+', v) else v
        net = plan.get('net', {})
        mcast = args.mcast or (None if args.lan else net.get('mcast'))
        lan = args.lan or (None if args.mcast else net.get('lan'))
        self.emu = bool(mcast)
        self.net = pdl.make_net(mcast, lan)
        v = plan.get('virtual', {})
        self.link = pdl.Link(self.net, v.get('number', 5), v.get('name', 'rig'), v.get('kind', 'cdj'),
                             on_event=self.on_event, announce=v.get('announce', True))
        self.sh = None                                   # stagehand.Stagehand once a `stagehand` step ran
        self.a9 = None
        self.deck = None
        self.results = []
        self.rec_tags = {}
        self.log('plan', name=plan.get('name'), vars=self.vars, net=mcast or lan, emu=self.emu)

    def on_event(self, kind, e):
        self.log(kind, **{k: v for k, v in e.items() if k != 't'})

    def deck_obj(self, player=None):
        # step `player: N` picks one of several of our decks (each on its own IP); default = vars ours / deck_ip
        if not isinstance(self.deck, dict):
            self.deck = {}
        ip = None if player is not None else self.vars.get('deck_ip')
        if not ip:
            d = self.link.devices.get(num(player if player is not None else self.vars.get('ours', 0)))
            ip = d and d['ip']
        if not ip:
            raise RuntimeError('our deck IP unknown (vars deck_ip or ours + discovery)')
        if ip not in self.deck:
            self.deck[ip] = Deck(self.link, ip, self.log)
        return self.deck[ip]

    # ---- step implementations: return (ok, detail)
    def st_wait_device(self, s):
        d = self.link.wait_device(num(s['player']), s.get('timeout', 60))
        return bool(d), d

    def st_wait(self, s):
        time.sleep(float(s.get('s', 1)))
        return True, None

    def st_deck(self, s):
        # optional when: [addr, mask, val] -- send the ops only if (u32 LE at addr) & mask == val (a state toggle
        # such as a panel that may already be open); SKIP otherwise
        if s.get('when'):
            a, mask, val = (num(x) for x in s['when'])
            b = self.deck_obj(s.get('player')).mem(a, 4)
            if b is None:
                return False, 'when: no memory answer'
            if int.from_bytes(b, 'little') & mask != val:
                return None, 'when: %s -> skipped' % b.hex(' ')
        ok, got = self.deck_obj(s.get('player')).send(s['ops'], s.get('done', True), s.get('timeout', 60))
        return ok, got

    def st_ensure(self, s):
        # {do: ensure, player: N, field: playing|synced|master, value: true, key: PLAY|SYNC|MASTER, timeout: 10}
        # presses `key` on our deck N only when its status field differs, then waits for the value
        pl = num(s['player'])
        self.link.wait(lambda: self.link.status.get(pl), 5)
        st = self.link.status.get(pl) or {}
        if match(st.get(s['field']), s['value']):
            return True, dict(already=True)
        ok, got = self.deck_obj(pl).send(['KEY ' + s['key'], 'WAIT 300'], True, 30)
        r = self.link.wait(lambda: match((self.link.status.get(pl) or {}).get(s['field']), s['value']),
                           s.get('timeout', 10))
        return bool(r), dict(pressed=s['key'], got=(self.link.status.get(pl) or {}).get(s['field']))

    def st_deck_mem(self, s):
        b = self.deck_obj(s.get('player')).mem(num(s['addr']), num(s['len']))
        if b is not None and s.get('as'):
            self.vars[s['as']] = b.hex()
        ok = b is not None
        # optional checks: want = [[off, mask, val], ...] on the u32 LE at off
        for off, mask, val in (s.get('want') or []) if ok else []:
            w = int.from_bytes(b[num(off):num(off) + 4].ljust(4, b'\0'), 'little')
            if (w & num(mask)) != num(val):
                ok = False
        return ok, b and b.hex(' ')

    def st_load(self, s):
        t = num(s['target'])
        slot = s.get('slot', 'usb')
        p = self.link.load_track(t, num(s['src_player']), pdl.SLOTS[slot] if slot in pdl.SLOTS else num(slot),
                                 num(s['rbid']), num(s.get('ttype', 1)))
        return True, p.hex()

    def st_fader(self, s):
        t = num(s['target'])
        p = self.link.fader_start(t, {num(s.get('player', t)): s['cmd']}, broadcast=s.get('broadcast', False))
        return True, p.hex()

    def st_sync(self, s):
        return True, self.link.sync(num(s['target']), bool(s.get('enable', True))).hex()

    def st_master(self, s):
        return True, self.link.become_master(num(s['target'])).hex()

    def st_onair(self, s):
        if self.a9 is not None:
            self.a9.onair = list(s['flags'])
            return True, 'fake A9 on-air %s' % s['flags']
        real = [d for d in self.link.devices.values() if d['dev'] >= 0x21]
        if real:
            return False, 'a mixer is on the network (%s): it owns on-air, not us' % real[0]['name']
        return True, self.link.on_air(s['flags']).hex()

    def st_fake_a9(self, s):
        lan_ok = self.plan.get('allow_fake_a9_lan') is True or self.args.allow_fake_a9_lan
        if not self.emu and not lan_ok:
            return False, ('fake_a9 is emulator-only (a second DJM-A9 identity hangs the real one); on an isolated '
                           'segment with NO real mixer: plan `allow_fake_a9_lan: true` or --allow-fake-a9-lan')
        if not s.get('enable', True):
            self.a9_stop()
            return True, 'off'
        if self.a9 is None and not self.emu:
            real = [d for d in self.link.devices.values() if d['dev'] >= 0x21]
            if real:
                return False, 'a mixer is already on the network (%s %s): no fake A9 here' % (real[0]['name'],
                                                                                            real[0]['ip'])
            if not s.get('ip'):
                return False, 'fake_a9 on the LAN needs `ip:` (its own alias on the DJ Link interface)'
            n = pdl.A9Net(s['ip'], bcast=self.net.bcast)
            self.link.taps.append(n.feed)
            self.a9_net = n
            self.a9 = pdl.FakeA9(n, mode=s.get('mode', 'auto'), onair=s.get('onair', (0, 1, 1, 1)),
                                 linkcue=s.get('linkcue', 1), ta_slots=s.get('ta_slots', (17, 18)),
                                 on_event=self.on_event)
            self.a9.audio.pcm_dir = os.path.join(self.args.out, 'pcm')
            self.a9.start()
            return True, 'fake A9 on the LAN at %s (%s)' % (s['ip'], s.get('mode', 'auto'))
        if self.a9 is None:
            g = '%s:%d' % self.net.dest
            n = pdl.McastSeg(g, my_ip=s.get('ip', '169.254.128.33'), my_mac='02:00:00:00:00:a9')
            self.a9 = pdl.FakeA9(n, mode=s.get('mode', 'auto'), onair=s.get('onair', (0, 1, 1, 1)),
                                 linkcue=s.get('linkcue', 1), ta_slots=s.get('ta_slots', (17, 18)),
                                 on_event=self.on_event)
            self.a9.start()
        else:
            self.a9.onair = list(s.get('onair', self.a9.onair))
            self.a9.set_linkcue(s.get('linkcue', self.a9.linkcue))
        return True, 'fake A9 %s' % s.get('mode', 'auto')

    def a9_stop(self):
        if self.a9:
            self.a9.run_ = False
            self.a9.join(2)
            self.a9 = None
        n = getattr(self, 'a9_net', None)
        if n:
            if n.feed in self.link.taps:
                self.link.taps.remove(n.feed)
            n.close()
            self.a9_net = None

    def st_a9_reset(self, s):
        """{do: a9_reset, tag: local_wav}: forget the audio stats (and start new PCM dumps under that tag)."""
        if not self.a9:
            return False, 'no fake A9'
        self.a9.audio.reset(s.get('tag'))
        return True, s.get('tag')

    def st_a9_stats(self, s):
        """{do: a9_stats, as: name}: log the fake A9's audio stats (all sources), never fails."""
        if not self.a9:
            return False, 'no fake A9'
        st = self.a9.audio.stats()
        self.log('a9_audio', tag=getattr(self.a9.audio, 'tag', None), stats=st,
                 elected=self.a9.elected, timing=self.a9.n_timing, rx_1e=self.a9.n_rx_1e, handover=self.a9.n_handover)
        return True, {ip: {k: v[k] for k in ('n', 'pcm', 'zero', 'i1', 'rate', 'gaps_n', 'gap_max_ms', 'peak', 'rms',
                                             'quiet_s')} for ip, v in st.items()}

    def st_expect_a9_audio(self, s):
        """{do: expect_a9_audio, ip: deck ip, timeout: 10, min_pcm: 100, rate: [130, 150], peak_gt: 300,
            max_gaps: 0, gap_ms: 15, quiet_gt: 1.0}  -- on the stats since the last a9_reset.
        quiet_gt: the source must have sent nothing for that long (the preview stopped)."""
        if not self.a9:
            return False, 'no fake A9'
        ip = s['ip']

        def ok():
            st = self.a9.audio.stats(ip).get(ip)
            if 'quiet_gt' in s:
                return (st is None or st['quiet_s'] > float(s['quiet_gt'])) and (st or True)
            if not st:
                return False
            if st['pcm'] < int(s.get('min_pcm', 1)):
                return False
            if 'rate' in s and not match(st['pcm_rate'], s['rate']):
                return False
            if 'peak_gt' in s and st['peak'] <= int(s['peak_gt']):
                return False
            if 'max_gaps' in s and st['gaps_n'] > int(s['max_gaps']):
                return False
            return st
        r = self.link.wait(ok, s.get('timeout', 10))
        st = self.a9.audio.stats(ip).get(ip)
        self.log('a9_audio', tag=getattr(self.a9.audio, 'tag', None), ip=ip, stats=st, elected=self.a9.elected)
        short = st and {k: st[k] for k in ('n', 'pcm', 'zero', 'i1', 'c_gaps', 'c_dups', 'pcm_rate', 'pcm_span_s',
                                           'gaps_n', 'gap_max_ms', 'peak', 'rms', 'quiet_s', 'bursts')}
        return bool(r), short

    # ---- Stagehand (mixer levels/faders from the real DJM-A9; stagehand.py). Shares self.net via link.taps.
    def st_stagehand(self, s):
        if self.sh is None:
            mixers = [s['mixer']] if s.get('mixer') else [d['ip'] for d in self.link.devices.values() if d['dev'] >= 0x21]
            self.sh = shd.Stagehand(self.net, s.get('name', 'Stagehand'), s.get('id') and num(s['id']), mixers=mixers,
                                    target=num(s.get('target', 3)), allow_write=bool(s.get('allow_write', False)),
                                    on_event=self.on_vu_event, own_rx=False)
            self.link.taps.append(self.sh.feed)
            self.sh.start()
        ok = self.sh.wait(lambda: self.sh.vu_hist or self.sh.mixer, s.get('timeout', 10))
        return bool(ok), self.sh.stats()

    def on_vu_event(self, kind, e):
        self.log(kind, **{k: v for k, v in e.items() if k != 't'})

    def st_expect_vu(self, s):
        """{do: expect_vu, channel: N, gt: 0.05 | lt: 0.01, window: 0.5, timeout: 10, hold: 3}"""
        if self.sh is None:
            return False, 'no stagehand step before expect_vu'
        ch, win = num(s['channel']), float(s.get('window', 0.5))

        def good():
            x = self.sh.vu_level(ch, win)
            return x is not None and ('gt' not in s or x > float(s['gt'])) and ('lt' not in s or x < float(s['lt']))
        r = self.sh.wait(good, s.get('timeout', 10))
        lv = self.sh.vu_level(ch, win)
        if r and s.get('hold'):
            end = time.monotonic() + float(s['hold'])
            lo = hi = lv
            while time.monotonic() < end:
                x = self.sh.vu_level(ch, win)
                lo, hi = min(lo, x if x is not None else -1), max(hi, x or 0)
                if not good():
                    return False, dict(channel=ch, broke=x, min=lo, max=hi)
                time.sleep(0.1)
            return True, dict(channel=ch, min=lo, max=hi)
        return bool(r), dict(channel=ch, level=lv, all={c: self.sh.vu_level(c, win) for c in range(1, 5)})

    def st_expect_mixer(self, s):
        """{do: expect_mixer, channel: N, fader: [200, 255], eq_low: [100, 156], timeout: 5} (0x39 fields)"""
        if self.sh is None:
            return False, 'no stagehand step before expect_mixer'
        ch = num(s['channel'])
        want = {k: v for k, v in s.items() if k not in EXPECT_SKIP + ('channel',)}

        def good():
            m = self.sh.mixer
            c = m and m['channels'].get(ch)
            return c and all(match(c.get(k), v) for k, v in want.items())
        r = self.sh.wait(good, s.get('timeout', 5))
        c = (self.sh.mixer or {}).get('channels', {}).get(ch, {})
        return bool(r), dict(want=want, got={k: c.get(k) for k in want})

    def st_expect(self, s):
        pl = num(s['player'])
        want = {k: v for k, v in s.items() if k not in EXPECT_SKIP}

        def ok():
            st = self.link.status.get(pl)
            return st and all(match(st.get(k), v) for k, v in want.items()) and st
        r = self.link.wait(ok, s.get('timeout', 10))
        st = self.link.status.get(pl) or {}
        got = {k: st.get(k) for k in want}
        if r and s.get('hold'):                          # must stay true for `hold` seconds
            end = time.monotonic() + float(s['hold'])
            while time.monotonic() < end:
                if not ok():
                    return False, dict(want=want, broke=got)
                time.sleep(0.1)
        return bool(r), dict(want=want, got=got)

    def st_expect_ack(self, s):
        pl = num(s['player'])
        ip = self.link.ip_of(pl)
        n0 = s.get('_n0', 0)
        r = self.link.wait(lambda: [a for a in self.link.acks[n0:] if a[1] == ip], s.get('timeout', 3))
        return bool(r), r and r[-1][3]

    def st_capture(self, s):
        st = self.link.status.get(num(s['player'])) or {}
        v = st.get(s['field'])
        self.vars[s['as']] = v
        return v is not None, {s['as']: v}

    def st_prompt(self, s):
        if self.args.unattended:
            return None, 'SKIP (unattended): ' + s['text']
        input('\n>>> %s  [Enter when done] ' % s['text'])
        return True, s['text']

    def st_shell(self, s):
        r = subprocess.run(s['cmd'], shell=True, capture_output=True, text=True, timeout=s.get('timeout', 60))
        return r.returncode == 0, (r.stdout + r.stderr).strip()[-300:]

    def run(self):
        self.link.start()
        hard_fail = False
        n_acks = 0
        for i, raw in enumerate(self.plan['steps']):
            s = subst(raw, self.vars)
            if True in s:                                   # YAML 1.1 reads a bare `on:` key as True
                s['enable'] = s.pop(True)
            if False in s:
                s['enable'] = not s.pop(False)
            if s['do'] == 'expect_ack':
                s['_n0'] = n_acks
            if s['do'] == 'load':
                n_acks = len(self.link.acks)
            label = s.get('name') or '%s %s' % (s['do'], ' '.join('%s=%s' % (k, v) for k, v in s.items()
                                                                 if k not in ('do', 'name', '_n0', 'soft')))[:100]
            self.log('step', i=i, label=label, step=raw)
            t0 = time.monotonic()
            try:
                ok, detail = getattr(self, 'st_' + s['do'])(s)
            except Exception as e:
                ok, detail = False, 'EXC %r' % e
            dt = round(time.monotonic() - t0, 2)
            res = 'SKIP' if ok is None else 'PASS' if ok else ('SOFT' if s.get('soft') else 'FAIL')
            self.log('result', i=i, label=label, res=res, dt=dt, detail=detail)
            print('%-4s %3d %-60s %6.2fs %s' % (res, i, label[:60], dt, json.dumps(detail, default=str)[:140]),
                  flush=True)
            self.results.append((i, label, res, dt, detail))
            if res == 'FAIL':
                hard_fail = True
                if not self.args.keep_going:
                    break
        self.finish()
        return 1 if hard_fail else 0

    def finish(self):
        for t, s, d in self.link.deck_records:
            self.rec_tags[d[:4].decode('latin1')] = self.rec_tags.get(d[:4].decode('latin1'), 0) + 1
        self.log('summary', counts={'%d/0x%02x' % k: v for k, v in sorted(self.link.counts.items())},
                 deck_record_tags=self.rec_tags, devices=self.link.devices, unknown=self.link.unknown_report(),
                 fake_a9=self.a9 and dict(timing=self.a9.n_timing, rx_1e=self.a9.n_rx_1e, handover=self.a9.n_handover))
        self.a9_stop()
        if self.sh:
            self.log('stagehand_summary', **self.sh.stats())
            self.sh.stop()
        self.link.stop()
        n = {r: sum(1 for x in self.results if x[2] == r) for r in ('PASS', 'FAIL', 'SOFT', 'SKIP')}
        lines = ['rig report: %s  (%s)' % (self.plan.get('name'), time.strftime('%Y-%m-%d %H:%M:%S')),
                 'net: %s   steps: %d   %s' % ('emulator' if self.emu else 'LAN', len(self.results),
                                                '  '.join('%s %d' % kv for kv in n.items())), '']
        for i, label, res, dt, detail in self.results:
            if res != 'PASS' or self.plan.get('report_all', True):
                lines.append('%-4s %3d %-64s %6.2fs' % (res, i, label[:64], dt))
                if res != 'PASS':
                    lines.append('          ' + json.dumps(detail, default=str)[:300])
        lines += ['', 'devices: ' + ', '.join('%d %s %s' % (d['dev'], d['name'], d['ip'])
                                             for d in sorted(self.link.devices.values(), key=lambda x: x['dev'])),
                  'packets: ' + ', '.join('%d/0x%02x:%d' % (k[0], k[1], v) for k, v in sorted(self.link.counts.items())),
                  'unknown packet kinds: %d (see rig.jsonl summary)' % len(self.link.unknown),
                  'log: %s' % os.path.join(self.args.out, 'rig.jsonl')]
        open(os.path.join(self.args.out, 'report.txt'), 'w').write('\n'.join(lines) + '\n')
        print('\n'.join(lines))


def load_plan(path):
    if path.endswith('.py'):
        spec = importlib.util.spec_from_file_location('plan', path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m.PLAN
    import yaml
    return yaml.safe_load(open(path))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('plan')
    ap.add_argument('--mcast')
    ap.add_argument('--lan')
    ap.add_argument('--out', default=os.path.join(HERE, 'runs', time.strftime('%Y%m%d_%H%M%S')))
    ap.add_argument('--set', action='append')
    ap.add_argument('--unattended', action='store_true')
    ap.add_argument('--keep-going', action='store_true')
    ap.add_argument('--allow-fake-a9-lan', action='store_true',
                    help='let fake_a9 run on a REAL network (isolated rig segment with no real mixer only)')
    a = ap.parse_args()
    sys.exit(Rig(load_plan(a.plan), a).run())


if __name__ == '__main__':
    main()

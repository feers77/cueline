#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Cueline Builder -- make the Cueline firmware update from YOUR official CDJ-2000NXS2 1.87 update.

    python3 cueline_patch.py C2KNXS2.UPD [OUTPUT.UPD]        (default output: Cueline/C2KNXS2.UPD next to the input)
    Windows: drag C2KNXS2.UPD onto CuelineBuilder.exe, or double-click it and pick the file.
    (In the repository: python3 builder/cueline_patch.py C2KNXS2.UPD -- it uses builder/cueline.delta.)

What it does, all locally on your computer, no network:
  1. checks that the input is the official 1.87 update (sha256);
  2. unpacks its GUI and MAIN images (the same open decoders build.sh uses);
  3. applies Cueline's prebuilt patch data (cueline.delta: our compiled mods and generated tables; every byte that
     comes from the stock firmware is referenced by offset into YOUR images, never stored in the delta);
  4. packs the update again and checks the result's sha256 against the published release.
No compiler is needed. The same result comes out of the full from-source build (build.sh) -- see README.
"""
import hashlib
import json
import lzma
import os
import re
import struct
import sys

HERE = getattr(sys, '_MEIPASS', None) or os.path.dirname(os.path.abspath(__file__))
for _d in (os.path.join(HERE, 'codec'), os.path.join(HERE, '..', 'scripts', 'firmware')):   # frozen exe / repository
    if os.path.isdir(_d):
        sys.path.insert(0, _d)
import gui_decode    # noqa: E402  (upstream GPL-2.0-or-later codec, see THIRD_PARTY.md)
import gui_encode    # noqa: E402
import main_decode   # noqa: E402
import main_encode   # noqa: E402

MAGIC = b'CUELDLT1'
DISCLAIMER = ("Disclaimer: Bricking your CDJ-2000NXS2 is hard but not impossible. The main risk is a power cut while "
              "the update is being written (flashing). Use a UPS if possible, don't touch the deck or unplug the USB "
              "stick during the update, and keep the official 1.87 update to go back to stock. Use at your own risk -- "
              "this project is unofficial and provided as-is, without warranty (see LICENSE).")
SECTION_OF = {'gui': 1, 'main': 3}
LABEL_VER, LABEL_VER_END = 19, 23


class Fail(Exception):
    pass


def sha(b):
    return hashlib.sha256(b).hexdigest()


def load_delta(path):
    raw = open(path, 'rb').read()
    if raw[:8] != MAGIC:
        raise Fail('%s is not a Cueline delta' % path)
    body = lzma.decompress(raw[8:])
    n = struct.unpack_from('<I', body, 0)[0]
    meta = json.loads(body[4:4 + n])
    return meta, body[4 + n:]


def parse_manifest(data):
    sizes, pos = [], 0
    while True:
        m = re.match(rb'(\d+)\r\n', data[pos:pos + 32])
        if not m:
            break
        sizes.append(int(m.group(1)))
        pos += m.end()
    if not sizes or pos + sum(sizes) != len(data):
        raise Fail('not a CDJ-2000NXS2 .UPD container')
    return sizes, pos


def apply_ops(stock, out_len, ops, blob):
    """Output = the stock image (resized to out_len, 0xFF past its end) with the ops applied:
    C dst src n = copy n bytes of the STOCK image from src; L dst off n = n literal bytes of the delta blob."""
    out = bytearray(stock[:out_len]) + b'\xff' * max(0, out_len - len(stock))
    for kind, dst, a, n in ops:
        if kind == 'C':
            out[dst:dst + n] = stock[a:a + n]
        else:
            out[dst:dst + n] = blob[a:a + n]
    return bytes(out)


def relabel(target, section, ver):
    sec = bytearray(section)
    sec[LABEL_VER:LABEL_VER_END] = ver.encode()
    crc = gui_encode.crc16_xmodem(bytes(sec[:-2]))
    sec[-2:] = struct.pack('>H' if target == 'gui' else '<H', crc)
    return bytes(sec)


def build(upd_path, out_path, delta_path, log=print):
    meta, blob = load_delta(delta_path)
    data = open(upd_path, 'rb').read()
    got = sha(data)
    if got != meta['stock_upd_sha256']:
        raise Fail('this is not the official CDJ-2000NXS2 1.87 update\n  expected sha256 %s\n  got      %s\n'
                   'Download C2KNXS2.UPD (firmware 1.87) from Pioneer DJ again and unzip it.'
                   % (meta['stock_upd_sha256'], got))
    log('input OK: official CDJ-2000NXS2 1.87 (sha256 %s...)' % got[:16])
    sizes, hdrlen = parse_manifest(data)
    sections, off = [], hdrlen
    for s in sizes:
        sections.append(data[off:off + s])
        off += s
    for target in ('gui', 'main'):
        t = meta['targets'][target]
        idx = SECTION_OF[target] - 1
        section = sections[idx]
        decode = gui_decode.decode if target == 'gui' else main_decode.decode
        image = decode(section)[3]
        if sha(image) != t['stock_image_sha256']:
            raise Fail('%s image of the input does not decode as expected' % target)
        log('%s: unpacked %d bytes, applying %d patch operations' % (target.upper(), len(image), len(t['ops'])))
        patched = apply_ops(image, t['out_len'], t['ops'], blob)
        if sha(patched) != t['out_image_sha256']:
            raise Fail('%s: patched image check failed (corrupt delta?)' % target)
        log('%s: packing (this takes a minute) ...' % target.upper())
        new = (gui_encode.encode(section[:32], patched, optimal=True) if target == 'gui'
               else main_encode.encode(section, patched, optimal=True))
        sections[idx] = relabel(target, new, t['label_ver'])
    out = b''.join(b'%d\r\n' % len(s) for s in sections) + b''.join(sections)
    osha = sha(out)
    if osha != meta['out_upd_sha256']:
        raise Fail('the result does not match the published release sha256 (%s != %s): do NOT install it'
                   % (osha, meta['out_upd_sha256']))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'wb') as f:
        f.write(out)
    log('wrote %s\n  sha256 %s == release %s (%s)' % (out_path, osha, meta['release'], meta['build_id']))
    log('Install: 1) unplug the Pro DJ Link (LAN) cable (while LINK is active the player does not allow '
        'DUPLICATION > DEFAULT); 2) UTILITY > DUPLICATION > DEFAULT (factory reset: it erases the deck settings, '
        'and without it the update can be skipped); 3) copy this file ALONE to the root of a small FAT32 USB stick '
        'and update the deck as with an official update. Never switch the deck off during the update.')
    log('Back to stock: unplug the LAN cable, UTILITY > DUPLICATION > DEFAULT, then install the official 1.87.')
    return osha


def default_out(upd_path):
    return os.path.join(os.path.dirname(os.path.abspath(upd_path)), 'Cueline', 'C2KNXS2.UPD')


def delta_path():
    for d in (HERE, os.path.dirname(os.path.abspath(sys.executable))):
        p = os.path.join(d, 'cueline.delta')
        if os.path.isfile(p):
            return p
    raise Fail('cueline.delta not found next to the program')


def gui_main():
    """Windows: double-click (file picker) or drag-and-drop; messages in a window."""
    import tkinter as tk
    from tkinter import filedialog, messagebox
    root = tk.Tk()
    root.withdraw()
    if not messagebox.askokcancel('Cueline Builder', DISCLAIMER + '\n\nContinue?'):
        return 1
    upd = sys.argv[1] if len(sys.argv) > 1 else filedialog.askopenfilename(
        title='Cueline Builder: choose your official CDJ-2000NXS2 1.87 C2KNXS2.UPD',
        filetypes=[('CDJ-2000NXS2 update', '*.UPD'), ('All files', '*.*')])
    if not upd:
        return 1
    lines = []
    try:
        build(upd, default_out(upd), delta_path(), log=lines.append)
        messagebox.showinfo('Cueline Builder', '\n'.join(lines))
        return 0
    except Fail as e:
        messagebox.showerror('Cueline Builder', '\n'.join(lines + ['', 'ERROR: %s' % e]))
        return 1


def _osa(script, *args):
    """Run an AppleScript with its text passed as arguments (no quoting); (ok, stdout)."""
    import subprocess
    r = subprocess.run(['osascript', '-e', 'on run argv', '-e', script, '-e', 'end run', *args],
                       capture_output=True, text=True)
    return r.returncode == 0, r.stdout.strip()


def mac_main():
    """macOS app: double-click (file picker) or drop the .UPD on the icon; native dialogs, no Tk."""
    ok, _ = _osa('display dialog (item 1 of argv) with title "Cueline Builder" '
                 'buttons {"Cancel", "Continue"} default button "Continue"', DISCLAIMER)
    if not ok:
        return 1
    files = [a for a in sys.argv[1:] if not a.startswith('-psn')]
    if files:
        upd = files[0]
    else:
        ok, upd = _osa('POSIX path of (choose file with prompt (item 1 of argv))',
                       'Cueline Builder: choose your official CDJ-2000NXS2 1.87 C2KNXS2.UPD')
        if not ok or not upd:
            return 1
    lines = []
    try:
        out = default_out(upd)
        build(upd, out, delta_path(), log=lines.append)
        ok, btn = _osa('button returned of (display dialog (item 1 of argv) with title "Cueline Builder" '
                       'buttons {"Show in Finder", "OK"} default button "OK")', '\n'.join(lines))
        if ok and btn == 'Show in Finder':
            import subprocess
            subprocess.run(['open', '-R', out])
        return 0
    except Fail as e:
        _osa('display dialog (item 1 of argv) with title "Cueline Builder" buttons {"OK"} '
             'default button "OK" with icon stop', '\n'.join(lines + ['', 'ERROR: %s' % e]))
        return 1


def main():
    if getattr(sys, 'frozen', False) and os.name == 'nt' and '--console' not in sys.argv:
        return gui_main()
    if getattr(sys, 'frozen', False) and sys.platform == 'darwin' and '--console' not in sys.argv:
        return mac_main()
    args = [a for a in sys.argv[1:] if a != '--console']
    print(DISCLAIMER + '\n')
    if not args or args[0] in ('-h', '--help'):
        print(__doc__)
        return 0 if args else 1
    try:
        build(args[0], args[1] if len(args) > 1 else default_out(args[0]),
              os.environ.get('CUELINE_DELTA') or delta_path())
        return 0
    except Fail as e:
        print('ERROR: %s' % e, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

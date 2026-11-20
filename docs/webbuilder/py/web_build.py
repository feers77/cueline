# SPDX-License-Identifier: Apache-2.0
"""Browser glue for the Cueline web builder: runs the UNCHANGED cueline_patch.build() under Pyodide.

The only substitution is the LZSS encoder's hot path (lzss_encode.pack_optimal), which can be handed a
byte-identical JavaScript port (lzss_fast.js) because the pure-Python one is ~3x slower under WebAssembly than
native. Everything else -- input sha check, GUI/MAIN decode, delta ops, S-records, CRCs, relabel and the final
release sha check -- is the same Python the desktop builders run, so a port mismatch can only fail the build.
"""
import sys

sys.path.insert(0, '/cueline')
import cueline_patch  # noqa: E402  (adds /cueline/codec to sys.path)
import lzss_encode    # noqa: E402

DISCLAIMER = cueline_patch.DISCLAIMER


def use_js_encoder(js_pack):
    from pyodide.ffi import to_js

    def pack_optimal(data):
        return js_pack(to_js(data)).to_bytes()
    lzss_encode.pack_optimal = pack_optimal


def run(inp, out, delta, log):
    """(output sha256, None) or (None, error text) -- cueline_patch.Fail becomes the error text."""
    try:
        return cueline_patch.build(inp, out, delta, log=log), None
    except cueline_patch.Fail as e:
        return None, str(e)

// SPDX-License-Identifier: Apache-2.0
// Cueline web builder worker: runs the unchanged builder/cueline_patch.py (+ the scripts/firmware codec)
// under Pyodide. The user's file stays in this worker's memory; nothing is uploaded anywhere.
'use strict';

const PY_FILES = [            // site path -> path in the Pyodide file system (same layout as the frozen exe)
  ['py/cueline_patch.py', '/cueline/cueline_patch.py'],
  ['py/web_build.py', '/cueline/web_build.py'],
  ['py/codec/lzss_decode.py', '/cueline/codec/lzss_decode.py'],
  ['py/codec/lzss_encode.py', '/cueline/codec/lzss_encode.py'],
  ['py/codec/gui_decode.py', '/cueline/codec/gui_decode.py'],
  ['py/codec/gui_encode.py', '/cueline/codec/gui_encode.py'],
  ['py/codec/main_decode.py', '/cueline/codec/main_decode.py'],
  ['py/codec/main_encode.py', '/cueline/codec/main_encode.py'],
];

importScripts('lzss_fast.js');

let pyReady = null;           // Promise<pyodide>, started on 'warm' so the runtime loads while the user picks a file

function post(type, extra) { self.postMessage(Object.assign({ type }, extra || {})); }

async function fetchBytes(url) {
  const r = await fetch(url, { cache: 'no-cache' });
  if (!r.ok) throw new Error('could not load ' + url + ' (HTTP ' + r.status + ')');
  return new Uint8Array(await r.arrayBuffer());
}

function loadRuntime(cfg) {
  if (pyReady) return pyReady;
  pyReady = (async () => {
    const t0 = performance.now();
    post('phase', { phase: 'runtime', text: 'Loading the Python runtime (Pyodide, ~10 MB, cached after the first time)' });
    importScripts(cfg.pyodide_index_url + 'pyodide.js');
    const py = await loadPyodide({ indexURL: cfg.pyodide_index_url, fullStdLib: false });
    await py.loadPackage('lzma', { messageCallback: () => {} });
    const files = await Promise.all(PY_FILES.map(([src]) => fetchBytes(src)));
    py.FS.mkdirTree('/cueline/codec');
    PY_FILES.forEach(([, dst], i) => py.FS.writeFile(dst, files[i]));
    const delta = await fetchBytes(cfg.delta);
    if (cfg.delta_sha256) {
      const got = hex(await crypto.subtle.digest('SHA-256', delta));
      if (got !== cfg.delta_sha256) throw new Error('the patch data (' + cfg.delta + ') is damaged: sha256 ' + got);
    }
    py.FS.writeFile('/cueline/cueline.delta', delta);
    py.runPython("import sys; sys.path.insert(0, '/cueline'); import web_build");
    if (cfg.engine !== 'py') py.globals.get('web_build').use_js_encoder((u8) => LZSS.packOptimal(u8));
    post('runtime-ready', { ms: performance.now() - t0 });
    return py;
  })();
  pyReady.catch(() => { pyReady = null; });
  return pyReady;
}

function hex(buf) {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function build(cfg, input) {
  const py = await loadRuntime(cfg);
  const t0 = performance.now();
  py.FS.writeFile('/in.UPD', new Uint8Array(input));
  input = null;
  const log = (s) => post('log', { text: String(s), ms: performance.now() - t0 });
  const res = py.globals.get('web_build').run('/in.UPD', '/out/C2KNXS2.UPD', '/cueline/cueline.delta', log);
  try {
    const [osha, err] = res.toJs();
    if (err) { post('fail', { text: err }); return; }
    const out = py.FS.readFile('/out/C2KNXS2.UPD');      // a copy, so the FS file can go
    py.FS.unlink('/out/C2KNXS2.UPD');
    const buf = out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
    self.postMessage({ type: 'done', sha: osha, ms: performance.now() - t0, data: buf }, [buf]);
  } finally {
    res.destroy();
    try { py.FS.unlink('/in.UPD'); } catch (e) { /* already gone */ }
  }
}

self.onmessage = (ev) => {
  const m = ev.data;
  const run = m.type === 'warm' ? loadRuntime(m.config) : build(m.config, m.data);
  run.catch((e) => post('error', { text: (e && e.message) || String(e) }));
};

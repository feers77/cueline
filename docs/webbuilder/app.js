// SPDX-License-Identifier: Apache-2.0
// Cueline web builder page logic. The heavy work happens in worker.js; this file only drives the steps.
'use strict';

(() => {
  const $ = (id) => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  // phase -> [weight in the progress bar, expected seconds on a mid-range laptop]
  const PHASES = { check: [4, 1], runtime: [16, 12], gui: [40, 12], main: [36, 12], verify: [4, 1] };
  let config = null, worker = null, downloadUrl = null, busy = false, runtimeReady = false;
  const state = {};            // phase -> { status, t0 }

  function hex(buf) { return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join(''); }

  function setPhase(p, status) {
    const li = document.querySelector('#phases li[data-p="' + p + '"]');
    const prev = state[p] || {};
    state[p] = { status, t0: status === 'run' ? (prev.t0 || performance.now()) : prev.t0, t1: status !== 'run' ? performance.now() : 0 };
    li.className = status;
    if (status !== 'run' && state[p].t0) li.querySelector('.t').textContent = ((state[p].t1 - state[p].t0) / 1000).toFixed(1) + ' s';
    if (status === 'ok' && !state[p].t0) li.querySelector('.t').textContent = 'cached';
    tick();
  }

  function tick() {
    let total = 0, done = 0;
    for (const [p, [w, secs]] of Object.entries(PHASES)) {
      total += w;
      const s = state[p];
      if (!s) continue;
      if (s.status === 'ok') done += w;
      else if (s.status === 'run') {
        const el = (performance.now() - s.t0) / 1000;
        done += w * (1 - Math.exp(-el / secs)) * 0.95;            // creeps towards the end, never claims it
        const t = document.querySelector('#phases li[data-p="' + p + '"] .t');
        if (t) t.textContent = el.toFixed(0) + ' s';
      }
    }
    $('bar').value = Math.round(100 * done / total);
  }
  setInterval(() => { if (busy) tick(); }, 250);

  function fail(text) {
    busy = false;
    for (const p of Object.keys(PHASES)) if (state[p] && state[p].status === 'run') setPhase(p, 'bad');
    $('error').textContent = text;
    $('error').hidden = false;
    $('retry').hidden = false;
    $('status').textContent = 'Nothing was written. ';
    document.title = 'Cueline Builder';
  }

  function resetBuild() {
    for (const k of Object.keys(state)) delete state[k];
    document.querySelectorAll('#phases li').forEach((li) => { li.className = ''; li.querySelector('.t').textContent = ''; });
    $('error').hidden = true; $('retry').hidden = true; $('s-done').hidden = true;
    $('bar').value = 0;
    if (downloadUrl) { URL.revokeObjectURL(downloadUrl); downloadUrl = null; }
  }

  function startWorker() {
    if (worker) return;
    worker = new Worker('worker.js');
    worker.onmessage = onWorker;
    worker.onerror = (e) => fail('The builder stopped unexpectedly: ' + (e.message || 'worker error') +
      '\nTry an up-to-date desktop browser (Chrome, Edge, Firefox or Safari), or the desktop builder.');
    worker.postMessage({ type: 'warm', config });
  }

  function onWorker(ev) {
    const m = ev.data;
    if (m.type === 'runtime-ready') { runtimeReady = true; window.cuelineRuntimeMs = m.ms; if (state.runtime) setPhase('runtime', 'ok'); }
    else if (m.type === 'log') {
      const t = m.text;
      if (/^input OK/.test(t)) setPhase('check', 'ok');
      else if (/^GUI: unpacked/.test(t)) setPhase('gui', 'run');
      else if (/^MAIN: unpacked/.test(t)) { setPhase('gui', 'ok'); setPhase('main', 'run'); }
      else if (/^wrote /.test(t)) { setPhase('main', 'ok'); setPhase('verify', 'run'); }
      if (params.has('debug')) console.log('[builder ' + (m.ms / 1000).toFixed(1) + ' s] ' + t);
    } else if (m.type === 'fail' || m.type === 'error') {
      fail(m.text);
      worker.terminate(); worker = null; runtimeReady = false;   // start clean next time (and give the memory back)
    } else if (m.type === 'done') finish(m);
  }

  async function finish(m) {
    let sha = m.sha;
    if (crypto.subtle) sha = hex(await crypto.subtle.digest('SHA-256', m.data));     // independent re-check
    if (sha !== m.sha || sha !== config.output_sha256) {
      fail('The result does not match the published ' + config.version_label + ' sha256:\n  expected ' +
        config.output_sha256 + '\n  got      ' + sha + '\nDo NOT install anything from this run.');
      return;
    }
    setPhase('verify', 'ok');
    busy = false;
    worker.terminate(); worker = null; runtimeReady = false;
    const blob = new Blob([m.data], { type: 'application/octet-stream' });
    downloadUrl = URL.createObjectURL(blob);
    const a = $('download');
    a.href = downloadUrl;
    a.download = config.output_name;
    a.textContent = 'Download ' + config.output_name;
    $('okmsg').textContent = config.version_label + ' built in ' + (m.ms / 1000).toFixed(0) + ' s and verified.\nsha256 ' + sha +
      '\n(' + blob.size.toLocaleString('en') + ' bytes, matches the published release)';
    $('status').textContent = 'Done.';
    $('s-done').hidden = false;
    $('s-done').scrollIntoView({ behavior: 'smooth', block: 'start' });
    document.title = 'Ready - Cueline Builder';
  }

  async function onFile(file) {
    if (!file || busy) return;
    resetBuild();
    busy = true;
    $('s-build').setAttribute('aria-disabled', 'false');
    $('status').textContent = 'Usually under a minute. Keep this tab open.';
    document.title = 'Building - Cueline Builder';
    setPhase('check', 'run');
    const wrongFile = (got) => 'This is not the official CDJ-2000NXS2 1.87 update (' + file.name + ').\n' +
      (got ? '  expected sha256 ' + config.input_sha256 + '\n  got      ' + got + '\n' : '') +
      'Download C2KNXS2.UPD (firmware 1.87) from Pioneer DJ again and unzip it. Do not use an already patched file.';
    if (config.input_size && file.size !== config.input_size) {
      fail(wrongFile(null) + '\n(size ' + file.size.toLocaleString('en') + ' bytes, expected ' + config.input_size.toLocaleString('en') + ')');
      return;
    }
    let data;
    try { data = await file.arrayBuffer(); } catch (e) { fail('Could not read the file: ' + e.message); return; }
    if (crypto.subtle) {                        // fast check here; the Python builder checks it again
      const got = hex(await crypto.subtle.digest('SHA-256', data));
      if (got !== config.input_sha256) { fail(wrongFile(got)); return; }
      setPhase('check', 'ok');
    }
    startWorker();
    setPhase('runtime', runtimeReady ? 'ok' : 'run');
    worker.postMessage({ type: 'build', config, data }, [data]);
  }

  function enable(on) {
    $('s-file').setAttribute('aria-disabled', on ? 'false' : 'true');
    $('file').disabled = !on;
    if (on) startWorker();                     // load the runtime while the user looks for the file
  }

  async function init() {
    try {
      const r = await fetch('config.json', { cache: 'no-cache' });
      config = await r.json();
    } catch (e) {
      $('disclaimer').textContent = 'Could not load config.json: ' + e.message;
      return;
    }
    if (params.get('engine') === 'py') config.engine = 'py';    // pure-Python encoder (slow; for comparison)
    $('ver').textContent = config.version_label;
    $('readme').href = config.readme_url;
    $('stock').href = config.back_to_stock_url;
    $('discord').href = config.discord_url;
    $('src').href = config.readme_url.replace(/#.*$/, '');
    if (typeof Worker === 'undefined' || typeof WebAssembly === 'undefined') {
      $('disclaimer').textContent = 'This browser cannot run the builder (no Web Workers / WebAssembly). Use an up-to-date desktop browser or the desktop builder.';
      return;
    }
    $('agree').addEventListener('change', (e) => enable(e.target.checked));
    if ($('agree').checked) enable(true);
    $('file').addEventListener('change', (e) => onFile(e.target.files[0]));
    $('again').addEventListener('click', () => { $('file').value = ''; $('file').click(); });
    const drop = $('drop');
    ['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('hover'); }));
    ['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('hover'); }));
    drop.addEventListener('drop', (e) => { if (!$('file').disabled) onFile(e.dataTransfer.files[0]); });
    window.addEventListener('dragover', (e) => e.preventDefault());       // a missed drop must not navigate away
    window.addEventListener('drop', (e) => e.preventDefault());
    window.addEventListener('beforeunload', (e) => { if (busy) { e.preventDefault(); e.returnValue = ''; } });
  }
  init();
})();

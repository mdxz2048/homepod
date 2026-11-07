#!/usr/bin/env node
// chrome_audio_diag.mjs — automated Chrome audio diagnostic harness (macOS).
//
// Interface with 017: accepts a LOCAL media file and an OUTPUT directory.
//   node chrome_audio_diag.mjs --media <local-media-file> --out <out-dir>
//
// What it does:
//   1. Serves the local media through a 127.0.0.1-only HTTP server and loads it
//      in a plain <video> element (ordinary HTML playback, NO arbitrary site,
//      NO personal profile).
//   2. Launches ONLY its own Google Chrome instance with remote debugging
//      bound to 127.0.0.1 and a brand new isolated temp profile; it closes only
//      that process and never touches the user's Chrome.
//   3. Collects the audio hardware-delay evidence channel three ways:
//        - Browser.getHistogram for Media.Audio.Mac.HardwareLatency.Output.{AudioUnit,Device,Stream,Total}
//          and Media.Audio.Render.SystemDelay (before -> after playback deltas)
//        - Browser.getHistograms filtered to Media.Audio* for discovery (saved)
//        - CDP Tracing.start/end over categories "audio,..." and extracts
//          AUHAL stream frame / hardware_latency_us / playout delay evidence
//   4. Writes report.json + evidence.json into <out-dir> and prints a compact
//      summary. No HAL writes, no system output changes, no HomePod/Flow use.

import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, statSync, readFileSync, copyFileSync, symlinkSync, realpathSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, basename, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const DEFAULT_CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HIST_NAMES = [
  'Media.Audio.Mac.HardwareLatency.Output.AudioUnit',
  'Media.Audio.Mac.HardwareLatency.Output.Device',
  'Media.Audio.Mac.HardwareLatency.Output.Stream',
  'Media.Audio.Mac.HardwareLatency.Output.Total',
  'Media.Audio.Render.SystemDelay',
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function log(msg) {
  process.stdout.write(`[diag] ${msg}\n`);
}

function parseArgs(argv) {
  const a = {};
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--media' || k === '--out' || k === '--chrome') {
      a[k.slice(2)] = argv[++i];
    } else if (k === '--play-sec') {
      a.playSec = Number(argv[++i]);
    } else if (k === '--port') {
      a.port = Number(argv[++i]);
    } else if (k === '--help') {
      a.help = true;
    }
  }
  return a;
}

function usage() {
  console.log(`Usage:
  node chrome_audio_diag.mjs --media <local-media-file> --out <out-dir> [options]

Options:
  --media <path>   Local video file (audio+video muxed). Required.
  --out <dir>      Output directory for report + evidence. Required.
  --chrome <path>  Chrome binary. Default: ${DEFAULT_CHROME}
  --play-sec <n>   Playback window seconds (default 8).
  --port <n>       Debug port; 0 = auto (default).
`);
}

function mimeFor(p) {
  const e = extname(p).toLowerCase();
  if (e === '.mp4' || e === '.m4v') return 'video/mp4';
  if (e === '.webm') return 'video/webm';
  if (e === '.ogv' || e === '.ogg') return 'video/ogg';
  if (e === '.mov') return 'video/quicktime';
  return 'application/octet-stream';
}

class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.seq = 0;
    this.pending = new Map();
  }
  async open() {
    const ws = new WebSocket(this.wsUrl);
    this.ws = ws;
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve: res, reject: rej } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) rej(new Error(`${msg.error.message || 'cdp-error'}`));
        else res(msg.result);
      }
    });
    await new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', () => rej(new Error('ws error')), { once: true });
    });
  }
  send(method, params = {}) {
    return new Promise((resolveP, reject) => {
      const id = ++this.seq;
      this.pending.set(id, { resolve: resolveP, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() {
    try { this.ws.close(); } catch {}
  }
}

function pickFreePort(host = '127.0.0.1') {
  return new Promise((resolveP, reject) => {
    const net = createServer();
    net.on('error', reject);
    net.listen(0, host, () => {
      const a = net.address();
      net.close(() => resolveP(a.port));
    });
  });
}

async function waitHttpJson(url, timeoutMs, label) {
  const t0 = Date.now();
  let lastErr = '';
  while (Date.now() - t0 < timeoutMs) {
    try {
      const r = await fetch(url);
      if (r.ok) return r.json();
      lastErr = `http ${r.status}`;
    } catch (e) {
      lastErr = e.message;
    }
    await sleep(200);
  }
  throw new Error(`timeout waiting for ${label} at ${url}: ${lastErr}`);
}

async function getJson(url) {
  const r = await fetch(url);
  return r.json();
}

const PLAYER_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>ct-diag</title></head>
<body style="background:#111">
<video id="v" autoplay loop playsinline style="width:640px;height:360px"></video>
<script>
window.addEventListener('load', () => {
  const v = document.getElementById('v');
  v.src = '/media';
  v.volume = 1.0;
  v.muted = false;
});
</script>
</body></html>
`;

function startStaticServer(dir, mediaPath) {
  const mediaName = 'media' + extname(mediaPath);
  const mime = mimeFor(mediaPath);
  const handler = (req, res) => {
    try {
      if (req.url === '/' || req.url === '/player.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(PLAYER_HTML);
      } else if (req.url.startsWith('/media')) {
        res.writeHead(200, { 'Content-Type': mime, 'Accept-Ranges': 'bytes' });
        res.end(readFileSync(join(dir, mediaName)));
      } else {
        res.writeHead(404); res.end('nf');
      }
    } catch (e) {
      res.writeHead(500); res.end(String(e));
    }
  };
  return new Promise((resP, rej) => {
    const srv = createServer(handler);
    srv.on('error', rej);
    srv.listen(0, '127.0.0.1', () => resP(srv));
  });
}

function extractTraceEvents(events) {
  const out = {
    eventCount: 0,
    relevantCount: 0,
    uniqueNames: new Set(),
    streamFramesEvents: [],
    hardwareLatencySamples: [],
    playoutDelaySamples: [],
  };
  for (const ev of events) {
    if (!ev || typeof ev !== 'object') continue;
    out.eventCount++;
    const name = ev.name || '';
    const cat = ev.cat || '';
    const args = ev.args || {};
    if (/audio/i.test(cat) || /AUHAL/i.test(name) || /playout/i.test(name) || /latency/i.test(name)) {
      out.uniqueNames.add(name);
      out.relevantCount++;
    }
    if (args.output_buffer_size !== undefined) {
      out.streamFramesEvents.push({ name, ph: ev.ph, ts: ev.ts, args: { input_buffer_size: args.input_buffer_size, output_buffer_size: args.output_buffer_size, sample_rate: args.sample_rate } });
    }
    if (args.hardware_latency_us !== undefined) {
      out.hardwareLatencySamples.push(args.hardware_latency_us);
    }
    if (args.source_request_playout_delay_us !== undefined) {
      out.playoutDelaySamples.push(args.source_request_playout_delay_us);
    }
  }
  const frames = out.streamFramesEvents
    .filter((e) => e.ph === 'B' || e.ph === 'X' || !e.ph)
    .map((e) => e.args.output_buffer_size);
  const totalFrames = frames.reduce((a, b) => a + b, 0);
  return {
    eventCount: out.eventCount,
    relevantCount: out.relevantCount,
    uniqueRelevantNames: [...out.uniqueNames].sort(),
    streamFrameEvents: out.streamFramesEvents.length,
    streamFramesTotal: totalFrames,
    streamFrameSamples: frames.slice(0, 50),
    hardwareLatencyUsSamples: out.hardwareLatencySamples.slice(0, 100),
    playoutDelayUsSamples: out.playoutDelaySamples.slice(0, 100),
  };
}

async function runDiag(cfg) {
  const outDir = resolve(cfg.out);
  mkdirSync(outDir, { recursive: true });
  const mediaPath = realpathSync(cfg.media);
  if (!statSync(mediaPath).isFile()) throw new Error('media is not a file: ' + mediaPath);

  const runDir = mkdtempSync(join(outDir, 'run-'));
  const serveDir = join(runDir, 'serve');
  mkdirSync(serveDir, { recursive: true });
  const mediaTargetName = 'media' + extname(mediaPath);
  const mediaTargetPath = join(serveDir, mediaTargetName);
  let linked = false;
  try { symlinkSync(mediaPath, mediaTargetPath); linked = true; } catch { copyFileSync(mediaPath, mediaTargetPath); }

  const profileDir = mkdtempSync(join(tmpdir(), 'ct-profile-'));

  const srv = await startStaticServer(serveDir, mediaPath);
  const httpPort = srv.address().port;
  const pageUrl = `http://127.0.0.1:${httpPort}/player.html`;
  const debugPort = cfg.port || (await pickFreePort());
  const chromePath = cfg.chrome || DEFAULT_CHROME;

  const args = [
    '--headless=new',
    `--remote-debugging-port=${debugPort}`,
    '--remote-debugging-address=127.0.0.1',
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-sync',
    '--disable-extensions',
    '--autoplay-policy=no-user-gesture-required',
    '--disable-gpu',
    'about:blank',
  ];

  log(`chrome: ${chromePath}`);
  log(`debug port: ${debugPort}, http port: ${httpPort}, profile: ${profileDir}, media: ${mediaPath} (${linked ? 'symlink' : 'copy'})`);
  const child = spawn(chromePath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let chromeLog = '';
  child.stdout.on('data', (d) => { chromeLog += d.toString(); });
  child.stderr.on('data', (d) => { chromeLog += d.toString(); });

  let browser = null;
  let page = null;
  let histBaseline = {};
  let histAfter = {};
  let histogramsMediaAudio = [];
  let gridErr = null;
  const evidence = {};
  try {
    const ver = await waitHttpJson(`http://127.0.0.1:${debugPort}/json/version`, 30000, 'devtools');
    browser = new CDP(ver.webSocketDebuggerUrl);
    await browser.open();
    const verInfo = await browser.send('Browser.getVersion');
    evidence.browser = {
      product: verInfo.product,
      protocolVersion: verInfo.protocolVersion,
      revision: verInfo.revision,
      jsVersion: verInfo.jsVersion || null,
    };

    histBaseline = {};
    for (const n of HIST_NAMES) {
      try {
        const r = await browser.send('Browser.getHistogram', { name: n, delta: false });
        histBaseline[n] = r.histogram;
      } catch (e) {
        histBaseline[n] = { error: e.message };
      }
    }

    try {
      const hs = await browser.send('Browser.getHistograms');
      histogramsMediaAudio = hs.histograms.filter((h) => /Media\.Audio/.test(h.name));
      evidence.histogramsMediaAudioCount = histogramsMediaAudio.length;
    } catch (e) {
      gridErr = { stage: 'Browser.getHistograms', error: e.message };
    }

    const targetInfo = await browser.send('Target.createTarget', { url: 'about:blank' });
    const targetId = targetInfo.targetId;
    let pageWsUrl = null;
    for (let i = 0; i < 50 && !pageWsUrl; i++) {
      const list = await getJson(`http://127.0.0.1:${debugPort}/json/list`).catch(() => []);
      const t = list.find((x) => x.id === targetId);
      if (t) pageWsUrl = t.webSocketDebuggerUrl;
      if (!pageWsUrl) await sleep(200);
    }
    if (!pageWsUrl) throw new Error('could not resolve page websocket for target ' + targetId);
    page = new CDP(pageWsUrl);
    await page.open();
    await page.send('Page.enable');
    await page.send('Runtime.enable');
    await page.send('Page.navigate', { url: pageUrl });
    await sleep(1500);

    const startEval = await page.send('Runtime.evaluate', {
      expression: `(async()=>{ const v=document.getElementById('v'); v.muted=false; v.loop=true; try{ await v.play(); return {ok:true}; }catch(e){ return {error:String(e), code: e && e.name}; } })()`,
      awaitPromise: true,
      returnByValue: true,
    });
    evidence.playStart = startEval.result ? startEval.result.value : null;

    let traceReport = { error: 'not_run', collected: false };
    try {
      await page.send('Tracing.start', {
        categories: 'audio,disabled-by-default-audio',
        transferMode: 'ReturnAsStream',
      });
      await sleep(500);
      const playSec = Math.max(3, cfg.playSec || 8);
      const samples = [];
      for (let i = 0; i < playSec; i++) {
        const r = await page.send('Runtime.evaluate', {
          expression: `(()=>{ const v=document.getElementById('v'); const q=(v.getVideoPlaybackQuality)?v.getVideoPlaybackQuality():null; return {t:v.currentTime,paused:v.paused,readyState:v.readyState,ended:v.ended,audioDecodedBytes:(v.webkitAudioDecodedByteCount||0),videoFrames:(q?q.totalVideoFrames||0:(v.webkitDecodedFrameCount||0))}; })()`,
          returnByValue: true,
        });
        if (r.result && r.result.value) samples.push(r.result.value);
        await sleep(1000);
      }
      const traceEnd = await page.send('Tracing.end');
      let traceData = traceEnd.data;
      if (!Array.isArray(traceData) && traceEnd.stream) {
        const io = await page.send('IO.read', { handle: traceEnd.stream, size: 64 * 1024 * 1024 });
        try { traceData = JSON.parse(io.data || '[]'); } catch { traceData = []; }
      }
      const extracted = extractTraceEvents(Array.isArray(traceData) ? traceData : []);
      traceReport = { mode: 'cdp', collected: true, ...extracted };
      evidence.playbackSamples = samples;
    } catch (e) {
      traceReport = { error: e.message, collected: false };
    }
    evidence.trace = traceReport;

    histAfter = {};
    for (const n of HIST_NAMES) {
      try {
        const r = await browser.send('Browser.getHistogram', { name: n, delta: false });
        histAfter[n] = r.histogram;
      } catch (e) {
        histAfter[n] = { error: e.message };
      }
    }

    try { await browser.send('Browser.close'); } catch {}
  } catch (e) {
    gridErr = gridErr || { stage: 'main', error: e.message };
  } finally {
    if (page) page.close();
    if (browser) browser.close();
    await sleep(500);
    if (child.exitCode === null) child.kill('SIGTERM');
    await sleep(500);
    if (child.exitCode === null) child.kill('SIGKILL');
    srv.close();
  }

  const histDelta = {};
  for (const n of HIST_NAMES) {
    const a = histBaseline[n] || {};
    const b = histAfter[n] || {};
    if (typeof a.count === 'number' && typeof b.count === 'number') {
      histDelta[n] = { countBefore: a.count, countAfter: b.count, countDelta: b.count - a.count, sumAfter: b.sum || 0 };
    } else {
      histDelta[n] = { beforeError: a.error || null, afterError: b.error || null };
    }
  }

  const report = {
    kind: 'chrome-audio-diag',
    generatedAt: new Date().toISOString(),
    mac: { platform: process.platform, arch: process.arch, node: process.version },
    config: { media: mediaPath, out: outDir, playSec: cfg.playSec || 8, mode: cfg.mode || 'headless' },
    evidence,
    histograms: { baseline: histBaseline, after: histAfter, delta: histDelta },
    availableMediaAudioHistograms: histogramsMediaAudio.slice(0, 400),
    errors: gridErr ? [gridErr] : [],
    chromeLogTail: chromeLog.slice(-8000),
  };

  if (report.evidence.trace && report.evidence.trace.streamFramesTotal !== undefined) {
    report.streamFrames = {
      total: report.evidence.trace.streamFramesTotal,
      eventSamples: report.evidence.trace.streamFrameSamples,
      baselineAssessment: report.evidence.trace.streamFramesTotal === 0
        ? 'zero_reported_stream_frames (current baseline)'
        : 'nonzero_reported_stream_frames',
    };
  } else {
    report.streamFrames = { total: null, baselineAssessment: 'not_available' };
  }

  writeFileSync(join(outDir, 'report.json'), JSON.stringify(report, null, 2));
  writeFileSync(join(outDir, 'evidence.json'), JSON.stringify({ trace: report.evidence.trace || null, histogramsMediaAudio, histDelta }, null, 2));

  try { rmSync(profileDir, { recursive: true, force: true }); } catch {}
  try { rmSync(runDir, { recursive: true, force: true }); } catch {}

  log(`report -> ${join(outDir, 'report.json')}`);
  log(`streamFrames -> ${JSON.stringify(report.streamFrames)}`);
  log(`hist delta -> ${JSON.stringify(histDelta)}`);
  log(`trace summary -> ${JSON.stringify(report.evidence.trace)}`);
  if (gridErr) log(`errors -> ${JSON.stringify(gridErr)}`);
  return report;
}

const a = parseArgs(process.argv);
if (a.help) { usage(); process.exit(0); }
if (!a.media || !a.out) { usage(); process.exit(2); }
try {
  await runDiag({ media: a.media, out: a.out, chrome: a.chrome, playSec: a.playSec || 8, port: a.port || 0 });
} catch (e) {
  log('FATAL: ' + e.message);
  process.exit(1);
}
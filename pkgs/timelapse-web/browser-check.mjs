import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

const [hlsJs] = process.argv.slice(2);
assert(hlsJs, 'usage: node browser-check.mjs HLS.JS');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'timelapse-browser-'));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const requests = [];

function fixture() {
  const root = path.join(work, 'base'), range = path.join(root, 'ranges/2025-03');
  fs.cpSync(new URL('site', import.meta.url), root, { recursive: true });
  fs.mkdirSync(path.join(root, 'vendor'), { recursive: true });
  fs.copyFileSync(hlsJs, path.join(root, 'vendor/hls.min.js'));
  const media = path.join(work, 'media'); fs.mkdirSync(media);
  execFileSync('ffmpeg', ['-nostdin', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-t', '36', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '24', '-keyint_min', '24', '-sc_threshold', '0', '-f', 'hls', '-hls_time', '1', '-hls_segment_type', 'fmp4', '-hls_flags', 'independent_segments+single_file', '-hls_playlist_type', 'vod', '-hls_segment_filename', path.join(media, 'stream.mp4'), path.join(media, 'stream.m3u8')]);
  for (const camera of ['panorama', 'ptz']) for (const mode of ['x1', 'x6', 'x36']) {
    const dest = path.join(range, 'video', `${camera}-2025-03`, mode === 'x1' ? '' : mode); fs.mkdirSync(dest, { recursive: true });
    for (const name of ['stream.mp4', 'stream.m3u8']) fs.copyFileSync(path.join(media, name), path.join(dest, name));
  }
  fs.writeFileSync(path.join(root, 'catalog.json'), JSON.stringify({ cameras: ['panorama', 'ptz'], ranges: [{ id: '2025-03', start: '2025-03-18T00:00:00Z', end: '2025-03-21T00:00:00Z' }] }));
  fs.mkdirSync(path.join(range, 'subtitles'), { recursive: true }); fs.writeFileSync(path.join(range, 'subtitles/2025-03.vtt'), 'WEBVTT\n\n00:01.000 --> 00:02.000\nproof\n');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90', '-frames:v', '1', path.join(work, 'thumb.jpg')]);
  for (const height of [90, 180, 360]) for (const camera of ['panorama', 'ptz']) for (let hour = 0; hour < 72; hour += 6) {
    const date = new Date(Date.parse('2025-03-18T00:00:00Z') + hour * 3600000).toISOString().slice(0, 13).replace('T', '-');
    const dest = path.join(range, `thumbnails/h${height}/${camera}-${date}Z.jpg`); fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.copyFileSync(path.join(work, 'thumb.jpg'), dest);
  }
  return root;
}

function serve(root) {
  const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.m3u8': 'application/vnd.apple.mpegurl', '.mp4': 'video/mp4', '.vtt': 'text/vtt', '.jpg': 'image/jpeg' };
  const server = http.createServer((req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname), target = path.resolve(root, `.${pathname.endsWith('/') ? `${pathname}index.html` : pathname}`);
    if (!target.startsWith(`${root}${path.sep}`)) return res.writeHead(403).end();
    let stat; try { stat = fs.statSync(target); } catch { return res.writeHead(404).end(); } if (!stat.isFile()) return res.writeHead(404).end();
    const headers = { 'Accept-Ranges': 'bytes', 'Content-Type': mime[path.extname(target)] || 'application/octet-stream' }, match = req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    let start = 0, end = stat.size - 1, status = 200;
    if (match) { start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), end) : end; status = 206; }
    if (start > end || start >= stat.size) return res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` }).end();
    if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
    headers['Content-Length'] = end - start + 1; requests.push({ path: pathname, range: req.headers.range, status, at: Date.now() }); res.writeHead(status, headers);
    if (req.method === 'HEAD') res.end(); else fs.createReadStream(target, { start, end }).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port })));
}

async function browser(url, timeout = 12000) {
  const profile = fs.mkdtempSync(path.join(work, 'chrome-')), chromium = process.env.CHROMIUM || 'chromium', args = ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'];
  if (process.env.REQUIRE_HARDWARE === '1') args.splice(1, 0, '--use-angle=gl-egl');
  const child = spawn(chromium, args, { stdio: ['ignore', 'ignore', 'pipe'] }); let stderr = ''; child.stderr.on('data', (data) => { stderr += data; });
  const active = path.join(profile, 'DevToolsActivePort');
  for (let tries = 0; !fs.existsSync(active) && tries < 200; tries += 1) { if (child.exitCode !== null) throw new Error(`Chromium exited ${child.exitCode}: ${stderr}`); await sleep(25); }
  assert(fs.existsSync(active), `Chromium did not expose CDP: ${stderr}`);
  const [port] = fs.readFileSync(active, 'utf8').split('\n'), pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(), socket = new WebSocket(pages.find((item) => item.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let id = 0; const pending = new Map(), errors = [];
  socket.addEventListener('message', (event) => { const message = JSON.parse(event.data); if (message.id) { const callback = pending.get(message.id); pending.delete(message.id); callback?.(message); } else if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.text); });
  const send = (method, params = {}) => new Promise((resolve, reject) => { const sequence = ++id; pending.set(sequence, (message) => message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result)); socket.send(JSON.stringify({ id: sequence, method, params })); });
  await send('Runtime.enable'); await send('Page.enable'); await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__idbTouched=0;Object.defineProperty(window,'indexedDB',{get(){window.__idbTouched++;throw Error('IndexedDB forbidden by browser proof')}})` });
  await send('Page.navigate', { url });
  const evaluate = async (expression) => { const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); if (result.exceptionDetails) throw new Error(result.exceptionDetails.text); return result.result.value; };
  const waitFor = async (expression, label) => { const deadline = Date.now() + timeout; while (Date.now() < deadline) { if (await evaluate(expression)) return; await sleep(75); } throw new Error(`timeout: ${label}; page errors: ${errors.join('; ')}`); };
  const close = async () => { socket.close(); child.kill('SIGTERM'); await Promise.race([new Promise((resolve) => child.once('exit', resolve)), sleep(2000)]); if (child.exitCode === null) child.kill('SIGKILL'); };
  return { evaluate, waitFor, close };
}

async function prove(root, port, name) {
  requests.length = 0; const page = await browser(`http://127.0.0.1:${port}/${name}/#2025-03-18T12:00:00Z`, name === 'base' ? 12000 : 5000), states = [];
  const snapshot = () => page.evaluate(`(()=>{const v=[...document.querySelectorAll('video')];return {keys:[...document.querySelectorAll('.pane')].map(x=>x.dataset.sourceKey),paused:v.map(x=>x.paused),rates:v.map(x=>x.playbackRate),times:v.map(x=>x.currentTime),ready:v.map(x=>x.readyState),ahead:v.map(x=>{let n=0;for(let i=0;i<x.buffered.length;i++)if(x.buffered.end(i)>=x.currentTime)n=Math.max(n,x.buffered.end(i)-x.currentTime);return n}),controls:[document.querySelector('#play'),...document.querySelectorAll('.media-toggle')].map(x=>x.getAttribute('aria-label')),idb:window.__idbTouched}})()`);
  const speed = async (index, mode, playing, rate) => { await page.evaluate(`(()=>{const x=document.querySelector('.media-speed-slider');x.value=${index};x.dispatchEvent(new Event('input',{bubbles:true}))})()`); await page.waitFor(`(()=>{const p=[...document.querySelectorAll('.pane')],v=[...document.querySelectorAll('video')];return p.length===2&&p.every(x=>x.dataset.sourceKey?.endsWith(':${mode}'))&&v.every(x=>x.readyState>=3&&Math.abs(x.playbackRate-${rate})<1e-6&&x.paused===${!playing})})()`, `${mode} ${playing ? 'playing' : 'paused'}`); states.push(await snapshot()); };
  try {
    await page.waitFor(`document.querySelectorAll('video').length===2&&[...document.querySelectorAll('video')].every(x=>x.readyState>=3)`, 'two directly loaded panes');
    await page.waitFor(`[...document.querySelectorAll('video')].every(x=>{for(let i=0;i<x.buffered.length;i++)if(x.buffered.end(i)-x.currentTime>=8)return true;return false})`, 'ten-second buffers'); await sleep(700);
    const initial = await snapshot(); assert.deepEqual(initial.keys, ['2025-03:x1', '2025-03:x1']); assert(initial.paused.every(Boolean)); assert(initial.ready.every((x) => x >= 3)); assert(initial.times.every((x) => Math.abs(x - 6) < .2)); assert(initial.ahead.every((x) => x >= 8 && x <= 12.5), `unbounded initial buffers: ${initial.ahead}`); assert.equal(initial.idb, 0);
    const catalogAt = requests.find((x) => x.path.endsWith('/catalog.json'))?.at, firstMediaAt = requests.find((x) => x.path.endsWith('/stream.m3u8'))?.at; assert(firstMediaAt - catalogAt < 1500, 'media was gated after catalog load');
    await speed(0, 'x1', false, 1 / 12); await speed(5, 'x6', false, .25); await speed(11, 'x36', false, 2 / 3); await speed(4, 'x1', false, 1);
    await page.evaluate(`location.hash='#2025-03-18T18:00:00Z'`); await page.waitFor(`[...document.querySelectorAll('video')].every(x=>x.readyState>=3&&Math.abs(x.currentTime-9)<.2)`, 'hash seek');
    await page.evaluate(`(()=>{const r=document.querySelector('.timeline-track').getBoundingClientRect();window.dispatchEvent(new PointerEvent('pointermove',{clientX:r.left+r.width/2,clientY:r.top+r.height/2}))})()`); await page.waitFor(`document.querySelectorAll('#timeline-preview img').length===2`, 'thumbnail markup'); await sleep(200);
    await page.evaluate(`document.querySelector('#play').click()`); await page.waitFor(`[...document.querySelectorAll('video')].every(x=>!x.paused)`, 'play'); await speed(9, 'x6', true, 1); await speed(12, 'x36', true, 1);
    await page.evaluate(`(()=>{const v=document.querySelectorAll('video');v[1].currentTime=v[0].currentTime+2;v[0].dispatchEvent(new Event('timeupdate'))})()`); await page.waitFor(`(()=>{const v=document.querySelectorAll('video');return Math.abs(v[0].currentTime-v[1].currentTime)<.2})()`, 'follower correction');
    await page.evaluate(`(()=>{const v=document.querySelectorAll('video');v.forEach(x=>x.currentTime=x.duration-.18)})()`); await page.waitFor(`(()=>{const v=[...document.querySelectorAll('video')];return v.every(x=>x.paused)&&[document.querySelector('#play'),...document.querySelectorAll('.media-toggle')].every(x=>x.getAttribute('aria-label')==='Play')})()`, 'final EOF transport and controls');
    const final = await snapshot(), paths = requests.map((x) => x.path); assert(paths.some((x) => x.endsWith('.vtt'))); assert(paths.some((x) => x.endsWith('.jpg'))); for (const camera of ['panorama', 'ptz']) for (const mode of ['', '/x6', '/x36']) assert(paths.some((x) => x.includes(`${camera}-2025-03${mode}/stream.m3u8`)), `missing ${camera} ${mode || '/x1'}`);
    const mp4 = requests.filter((x) => x.path.endsWith('.mp4')); assert(mp4.length && mp4.every((x) => x.status === 206 && x.range), 'single-file HLS did not use valid ranges');
    const renderer = await page.evaluate(`(()=>{const g=document.createElement('canvas').getContext('webgl'),e=g&&g.getExtension('WEBGL_debug_renderer_info');return e?g.getParameter(e.UNMASKED_RENDERER_WEBGL):''})()`); if (process.env.REQUIRE_HARDWARE === '1') assert.match(renderer, /radeonsi|RADV|Radeon/i);
    return { renderer, initialAhead: initial.ahead.map((x) => +x.toFixed(2)), transitions: states.map((x) => ({ source: x.keys[0], playing: !x.paused[0], rate: x.rates[0] })), requests: requests.length, final: final.controls };
  } finally { await page.close(); }
}

const root = fixture(), app = fs.readFileSync(path.join(root, 'app.js'), 'utf8');
const mutations = [
  ['buffer-30', 'BUFFER_SECONDS = 10', 'BUFFER_SECONDS = 30'],
  ['buffer-2', 'BUFFER_SECONDS = 10', 'BUFFER_SECONDS = 2'],
  ['unsupported-pace', 'SPEED_FPS = [2, 4', 'SPEED_FPS = [1, 2, 4'],
  ['partial-pace', 'panes.forEach((pane) => pane.setRate(rate));', 'panes[0].setRate(rate);'],
  ['idb-gate', 'loadCatalog();', "indexedDB.open('gate'); loadCatalog();"],
  ['direct-load', 'hls.loadSource(url); hls.attachMedia(this.video);', 'hls.attachMedia(this.video);'],
  ['autoplay-gate', 'at, desiredPlaying));', 'at, true));'],
  ['play-control', 'setDesiredPlaying(!desiredPlaying);', 'setDesiredPlaying(false);'],
  ['hash-start', 'const initialTime = hashTime();', 'const initialTime = NaN;'],
  ['thumbnail-path', '`thumbnails/h${height}/${pathPart(camera)}-${pathPart(thumbnail.key)}.jpg`', '`missing/h${height}/${pathPart(camera)}-${pathPart(thumbnail.key)}.jpg`'],
  ['vtt-path', '`subtitles/${pathPart(range.id)}.vtt`', '`missing/${pathPart(range.id)}.vtt`'],
  ['follower-sync', '> .05) pane.seek(seconds)', '> 5) pane.seek(seconds)'],
  ['tier-path', "profile.mode === 'x1' ? base :", 'true ? base :'],
  ['final-eof', 'if (!next) { setDesiredPlaying(false); return; }', 'if (!next) return;'],
  ['one-pane', '.slice(0, 2)', '.slice(0, 1)'],
];
for (const [name, from, to] of mutations) { const dest = path.join(work, name); fs.cpSync(root, dest, { recursive: true }); assert(app.includes(from), `${name} mutation target missing`); fs.writeFileSync(path.join(dest, 'app.js'), app.replace(from, to)); }
const web = await serve(work);
try {
  const report = await prove(work, web.port, 'base'); console.log(JSON.stringify(report));
  if (process.env.TIMELAPSE_BROWSER_MUTATIONS === '1') for (const [name] of mutations) { let failure; try { await prove(work, web.port, name); } catch (error) { failure = error; } assert(failure, `${name} mutation escaped browser proof`); console.log(`mutation ${name}: rejected (${failure.message.split('\n')[0]})`); }
} finally { web.server.close(); fs.rmSync(work, { recursive: true, force: true }); }

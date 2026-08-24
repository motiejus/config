import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('site/app.js', import.meta.url), 'utf8');
const markup = fs.readFileSync(new URL('site/index.html', import.meta.url), 'utf8');

function hlsConfig(text) {
  const call = text.indexOf('new window.Hls(');
  assert.notEqual(call, -1, 'hls.js construction missing');
  const start = text.indexOf('{', call);
  let depth = 0;
  for (let index = start; index < text.length; index += 1) {
    if (text[index] === '{') depth += 1;
    if (text[index] === '}' && --depth === 0) return new Function('BUFFER_SECONDS', 'at', `return (${text.slice(start, index + 1)});`)(10, 12.5);
  }
  throw new Error('hls.js config is unbalanced');
}

function offeredRates(text) {
  const values = text.match(/SPEED_FPS = \[([^\]]+)\]/)?.[1].split(',').map(Number);
  assert(values?.every(Number.isFinite), 'playback pace list missing');
  return values.map((fps) => fps / (24 * (fps <= 24 ? 1 : fps <= 288 ? 6 : 36)));
}

function checkProduction(text, html) {
  assert.doesNotThrow(() => new Function(text), 'app.js must parse');
  assert.match(html, /<script src="vendor\/hls\.min\.js"><\/script>\s*<script src="app\.js"><\/script>/, 'hls.js must load before the app');
  assert.doesNotMatch(html, /<script[^>]+(?:async|onload|onerror)|hls-ready|timelapseHlsSettled/, 'script order must not manufacture readiness state');

  assert.match(text, /BUFFER_SECONDS = 10\b/, 'forward buffer must stay near ten seconds');
  assert.deepEqual(hlsConfig(text), { startPosition: 12.5, maxBufferLength: 10, maxMaxBufferLength: 10, backBufferLength: 0 }, 'hls.js must own positioning and a bounded in-memory window');
  assert.match(text, /hls\.loadSource\(url\); hls\.attachMedia\(this\.video\);/, 'hls.js must load directly');
  assert.match(text, /this\.video\.src = url; this\.video\.load\(\);/, 'native HLS must load directly');

  assert.match(text, /play\(\) \{ this\.video\.autoplay = true; this\.video\.play\(\)\.catch\(\(\) => undefined\); \}/, 'play must delegate to the media element');
  assert.match(text, /pause\(\) \{ this\.video\.autoplay = false; this\.setStatus\(''\); this\.video\.pause\(\); \}/, 'pause must delegate to the media element');
  assert.match(text, /setStatus\(status\) \{ this\.element\.querySelector\('\.buffer-indicator'\)\.hidden = status !== 'waiting'/, 'media status must own the buffering indicator');
  assert.match(text, /rate = activeFps\(\) \/ \(FPS \* profile\.stride\)/, 'pace must use the selected tier stride even while paused');
  assert(offeredRates(text).every((rate) => rate >= 1 / 16 && rate <= 16), 'every offered pace must be supported by Chromium');
  assert.match(text, /panes\.forEach\(\(pane\) => pane\.setRate\(rate\)\);\s*if \(key !== loadedSource\)/, 'rate rejection must happen before either pane changes tier');
  assert.match(text, /publishStream\(\) \{ this\.onStream\(this, \{ codec: 'AV1'/, 'published streams must report their fixed AV1 codec');
  assert.match(text, /if \(nextProfile\.mode !== previousProfile\.mode\) \{ slot = quantizedSlot\(nextProfile\); render\(\); load\(\); \}/, 'tier changes must attach their prebuilt stream');

  assert.match(text, /cameras = catalog\.cameras[\s\S]*?\.slice\(0, 2\)/, 'two panes must remain enabled');
  assert.match(text, /pane !== source && Math\.abs\(pane\.video\.currentTime - seconds\) > \.05\) pane\.seek\(seconds\)/, 'the follower must track the lead clock');
  assert.match(text, /const requested = Number\(source\.video\.dataset\.startPosition\);[\s\S]*?delete source\.video\.dataset\.startPosition/, 'the lead clock must ignore stale time until a requested seek arrives');
  assert.match(text, /pane\.video\.dataset\.startPosition !== undefined[\s\S]*?return slot/, 'pause must not sample stale time during a requested seek');
  assert.match(text, /function syncEnded\(source\)[\s\S]*?source !== panes\[0\]/, 'only the lead pane may roll to the next range');
  assert.match(text, /if \(!next\) \{ setDesiredPlaying\(false\); return; \}/, 'final EOF must stop both transports and repaint controls');

  assert.match(text, /const initialTime = hashTime\(\)/, 'hash-based initial seeking must remain enabled');
  assert.match(text, /window\.Hls\.Events\.ERROR[\s\S]*?data\.fatal\) this\.fail\(\)/, 'fatal hls.js errors must surface');
  assert.match(text, /this\.video\.addEventListener\('error',[\s\S]*?this\.fail\(\)/, 'native media errors must surface');
}

checkProduction(source, markup);

const mutations = [
  [`syntax`, `${source}}`, markup],
  [`script order`, source, markup.replace('<script src="vendor/hls.min.js"></script>\n  <script src="app.js"></script>', '<script src="app.js"></script>\n  <script src="vendor/hls.min.js"></script>')],
  [`script readiness`, source, markup.replace('<script src="vendor/hls.min.js"', '<script async src="vendor/hls.min.js"')],
  [`buffer constant`, source.replace('BUFFER_SECONDS = 10', 'BUFFER_SECONDS = 30'), markup],
  [`start position`, source.replace('startPosition: at', 'startPosition: 0'), markup],
  [`forward minimum`, source.replace('maxBufferLength: BUFFER_SECONDS', 'maxBufferLength: 30'), markup],
  [`forward maximum`, source.replace('maxMaxBufferLength: BUFFER_SECONDS', 'maxMaxBufferLength: 30'), markup],
  [`played-data eviction`, source.replace('backBufferLength: 0', 'backBufferLength: 30'), markup],
  [`hls direct load`, source.replace('hls.loadSource(url)', 'hls.loadSource(stagedUrl)'), markup],
  [`native direct load`, source.replace('this.video.src = url', 'this.video.src = stagedUrl'), markup],
  [`custom loader`, source.replace('startPosition: at', 'loader: customLoader, startPosition: at'), markup],
  [`play gate`, source.replace('this.video.play().catch', 'this.readyToPlay && this.video.play().catch'), markup],
  [`pause delegation`, source.replace('this.video.pause(); }', '/* paused elsewhere */ }'), markup],
  [`buffer indicator ownership`, source.replace("status !== 'waiting'", "status === 'waiting'"), markup],
  [`pace math`, source.replace('rate = activeFps() / (FPS * profile.stride)', 'rate = activeFps() / FPS'), markup],
  [`unsupported pace`, source.replace('SPEED_FPS = [2, 4', 'SPEED_FPS = [1, 2, 4'), markup],
  [`split tier`, source.replace('panes.forEach((pane) => pane.setRate(rate));\n      if (key !== loadedSource)', 'if (key !== loadedSource)'), markup],
  [`codec state`, source.replace("codec: 'AV1'", 'codec: this.video.dataset.codec'), markup],
  [`tier selection`, source.replace('if (nextProfile.mode !== previousProfile.mode)', 'if (desiredPlaying && nextProfile.mode !== previousProfile.mode)'), markup],
  [`camera count`, source.replace('.slice(0, 2)', '.slice(0, 1)'), markup],
  [`camera sync`, source.replace('> .05) pane.seek(seconds)', '> 5) pane.seek(seconds)'), markup],
  [`seek race`, source.replace('delete source.video.dataset.startPosition', 'return'), markup],
  [`pause race`, source.replace('pane.video.dataset.startPosition !== undefined || ', ''), markup],
  [`follower EOF`, source.replace('source !== panes[0] || !desiredPlaying', '!desiredPlaying'), markup],
  [`final EOF`, source.replace('if (!next) { setDesiredPlaying(false); return; }', 'if (!next) return;'), markup],
  [`hash start`, source.replace('const initialTime = hashTime()', 'const initialTime = NaN'), markup],
  [`hls errors`, source.replace('window.Hls.Events.ERROR', 'window.Hls.Events.IGNORED_ERROR'), markup],
  [`native errors`, source.replace("this.video.addEventListener('error'", "this.video.addEventListener('ignored-error'"), markup],
];

mutations.forEach(([name, text, html]) => assert.throws(() => checkProduction(text, html), `${name} mutation escaped`));
console.log('timelapse-web checks passed');

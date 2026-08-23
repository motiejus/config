(() => {
  'use strict';
  const FPS = 24, SPEED_FPS = [1, 2, 4, 6, 12, 24, 36, 48, 72, 96, 144, 288, 576, 864, 1152, 1728], NATIVE_SPEED_FPS = new Set([1, 6, 36]), DEFAULT_SPEED_INDEX = SPEED_FPS.indexOf(FPS), FRAME_INTERVAL_SECONDS = 300, THUMBNAIL_INTERVAL_MS = 6 * 60 * 60 * 1000, TIME_ZONE = 'Europe/Vilnius';
  const QUALITY_LADDERS = Object.freeze({ panorama: Object.freeze([[480, 136], [960, 272], [1920, 544], [3840, 1086]]), ptz: Object.freeze([[320, 180], [640, 360], [1280, 720], [1920, 1080]]) });
  const DEFAULT_SOURCE_TIME = Date.parse('2025-03-18T06:00:00Z');
  const root = document.querySelector('#app');
  const archiveBase = new URL(location.href);
  archiveBase.username = archiveBase.password = '';
  const archiveUrl = (path) => new URL(path, archiveBase).href;
  const hlsReady = window.Hls || window.timelapseHlsSettled ? Promise.resolve() : new Promise((resolve) => window.addEventListener('hls-ready', resolve, { once: true }));
  const partsFormat = new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const isTouchUi = () => window.matchMedia('(any-pointer: coarse), (max-width: 700px)').matches;
  const EXACT_PROFILE = Object.freeze({ mode: 'exact', stride: 1, direct: true });
  function playbackProfile(sourceFps) {
    if (sourceFps <= 24) return { mode: 'x1', stride: 1, direct: false };
    if (sourceFps <= 288) return { mode: 'x6', stride: 6, direct: false };
    return { mode: 'x36', stride: 36, direct: false };
  }
  const isFirefoxMac = () => /Firefox/.test(navigator.userAgent) && /Macintosh/.test(navigator.userAgent);
  const sourceKey = (range, profile) => `${range.id}:${profile.mode}`;
  const qualityLadder = (camera) => QUALITY_LADDERS[camera] || [];
  const playlistPath = (camera, range, profile, quality, direct = profile.direct) => {
    const base = `video/${camera}-${range.id}`, modeBase = profile.mode === 'x1' || profile.direct ? base : `${base}/${profile.mode}`;
    if (direct) return archiveUrl(`${modeBase}/${quality !== 'auto' ? quality : camera === 'panorama' ? 3840 : isFirefoxMac() ? 1280 : 1920}/stream.m3u8`);
    return archiveUrl(`${modeBase}/master.m3u8?full`);
  };
  const thumbnailPath = (height, camera, key) => archiveUrl(`thumbnails/h${height}/${camera}-${key}.jpg`);
  const utcThumbnailKey = (value) => `${new Date(Math.round(value / THUMBNAIL_INTERVAL_MS) * THUMBNAIL_INTERVAL_MS).toISOString().slice(0, 13).replace('T', '-')}Z`;
  const html = (text) => String(text).replace(/[&<>"']/g, (letter) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[letter]);
  const zoneParts = (value) => Object.fromEntries(partsFormat.formatToParts(value).filter((part) => part.type !== 'literal').map((part) => [part.type, part.value]));
  const dateKey = (value) => { const part = zoneParts(value); return `${part.year}-${part.month}-${part.day}`; };
  function localTime(date, hour) {
    const [year, month, day] = date.split('-').map(Number), guess = new Date(Date.UTC(year, month - 1, day, hour)), part = zoneParts(guess);
    return new Date(guess.getTime() - (Date.UTC(Number(part.year), Number(part.month) - 1, Number(part.day), Number(part.hour), Number(part.minute), Number(part.second)) - guess.getTime()));
  }
  const localNoon = (date) => localTime(date, 12);
  function localTimestamp(value) {
    const date = new Date(value), part = zoneParts(date), offset = Math.round((Date.UTC(Number(part.year), Number(part.month) - 1, Number(part.day), Number(part.hour), Number(part.minute), Number(part.second)) - date.getTime()) / 60000), sign = offset >= 0 ? '+' : '-', absolute = Math.abs(offset);
    return `${part.year}-${part.month}-${part.day}T${part.hour}:${part.minute}:${part.second}${sign}${String(Math.floor(absolute / 60)).padStart(2, '0')}:${String(absolute % 60).padStart(2, '0')}`;
  }
  function addDays(date, count) { const [year, month, day] = date.split('-').map(Number); return new Date(Date.UTC(year, month - 1, day + count)).toISOString().slice(0, 10); }
  function formatSpeed(sourceFps) {
    const minutes = sourceFps * 5;
    const source = minutes >= 1440 ? `${minutes / 1440} d/s` : minutes >= 60 ? `${minutes / 60} h/s` : `${minutes} min/s`;
    return source;
  }
  function cameraLabel(camera) { const value = String(camera), lower = value.toLowerCase(); return lower.includes('pano') ? 'Pano' : lower === 'ptz' ? 'PTZ' : value; }
  function codecLabel(codec) { const value = String(codec || '').toLowerCase(); if (!value || value.startsWith('avc1') || value.startsWith('avc3')) return 'H.264'; if (value.startsWith('hvc1') || value.startsWith('hev1')) return 'H.265'; if (value.startsWith('av01')) return 'AV1'; if (value.startsWith('vp09')) return 'VP9'; return codec; }
  function renderQualityOptions(camera) { return `<option value="auto">Auto</option>${qualityLadder(camera).map(([width, height]) => `<option value="${width}">${width}×${height}</option>`).join('')}`; }
  function renderStreamControl(camera) { return `<label class="media-stream"><span class="media-stream-info" data-stream-camera="${html(camera)}">${html(cameraLabel(camera))} · H.264 · —</span><select class="media-quality" data-quality-camera="${html(camera)}" aria-label="${html(cameraLabel(camera))} quality">${renderQualityOptions(camera)}</select></label>`; }
  function renderShortcutHelp() {
    return `<aside class="shortcut-help" aria-label="Keyboard navigation"><strong>Source-time keys</strong><dl><dt>, . · ⌘/Ctrl←→</dt><dd>frame − / + · pause</dd><dt>← / →</dt><dd>− / + 10 h</dd><dt>Shift← / →</dt><dd>− / + 2 h</dd><dt>↓ / ↑</dt><dd>− / + 5 d</dd><dt>Shift↓ / ↑</dt><dd>− / + 10 h</dd><dt>PgDn / PgUp</dt><dd>day − / +</dd><dt>Shift PgDn / PgUp</dt><dd>− / + 50 d</dd><dt>Timeline wheel</dt><dd>− / + 20 h</dd><dt>Space / P</dt><dd>play / pause</dd><dt>[ / ]</dt><dd>slower / faster</dd><dt>Home / End</dt><dd>first / last</dd><dt>F</dt><dd>fullscreen</dd></dl></aside>`;
  }
  function renderPane(camera, cameras) {
    const ptzChrome = camera === 'ptz' ? `<div class="media-speed-control"><div class="media-streams">${cameras.map(renderStreamControl).join('')}</div><output class="media-speed" aria-label="Current playback speed">${formatSpeed(FPS)}</output><input class="media-speed-slider" type="range" min="0" max="${SPEED_FPS.length - 1}" step="1" value="${DEFAULT_SPEED_INDEX}" aria-label="Playback speed" aria-valuetext="${html(formatSpeed(FPS))}"></div>${renderShortcutHelp()}` : '';
    return `<section class="pane" data-camera="${html(camera)}"><div class="media"><video muted playsinline preload="none" disablePictureInPicture></video><canvas class="freeze" aria-hidden="true" hidden></canvas><img class="preview" alt="Timeline preview" hidden><p class="outage" hidden></p><button class="media-toggle" type="button" aria-label="Play"><span aria-hidden="true">▶</span><span class="media-toggle-label">Play</span></button>${ptzChrome}</div></section>`;
  }
  function renderSpeedOptions() { return SPEED_FPS.map((fps, index) => `<option value="${index}"${index === DEFAULT_SPEED_INDEX ? ' selected' : ''}>${html(formatSpeed(fps))}</option>`).join(''); }
  function renderTimeline(total, cameras) {
    return `<aside id="timeline" class="timeline" aria-label="Archive timeline"><button id="play" class="timeline-play" type="button" aria-label="Play">Play</button><div class="timeline-track"><input id="scrubber" type="range" min="0" max="${total - 1}" value="0" step="1" aria-label="Browse every five minutes"><div id="ticks" class="ticks"></div><div id="hover-marker" class="hover-marker"><span id="hover-date"></span></div></div><div id="timeline-preview" class="timeline-preview" aria-hidden="true"></div><button id="layout" class="timeline-button" type="button" aria-label="Show inset view" aria-pressed="false">▣</button><button id="settings" class="timeline-button mobile-only" type="button" aria-label="Playback speed, ${html(formatSpeed(FPS))}" aria-expanded="false" aria-controls="speed-menu">⚙</button><div id="speed-menu" class="speed-menu mobile-only" role="group" aria-label="Playback options"><div class="mobile-streams">${cameras.map(renderStreamControl).join('')}</div><label for="mobile-speed">Playback speed</label><select id="mobile-speed">${renderSpeedOptions()}</select></div><button id="fullscreen" class="timeline-button" type="button" aria-label="Fullscreen">⛶</button></aside>`;
  }
  function renderWatch(cameras, total) {
    return `<section class="watch"><div class="panes">${cameras.map((camera) => renderPane(camera, cameras)).join('<div class="pane-splitter" aria-label="Resize panes"></div>')}</div>${renderTimeline(total, cameras)}<div id="camera-statuses" class="camera-statuses" aria-live="polite"></div><output id="touch-seek-feedback" class="touch-seek-feedback" aria-live="polite"></output></section>`;
  }
  function renderError(message) { return `<p class="error">Could not open the archive: ${html(message)}</p>`; }

  class Pane {
    constructor(element, camera, onTime, onEnded, onStatus, onStream, onTouchTap) {
      this.element = element; this.camera = camera; this.video = element.querySelector('video'); this.freeze = element.querySelector('.freeze'); this.preview = element.querySelector('.preview'); this.hls = null; this.lockedHigh = false; this.range = null; this.target = null; this.status = null; this.wantsPlayback = false; this.onStatus = onStatus; this.onStream = onStream; this.streamCodec = 'H.264'; this.streamKey = ''; this.quality = 'auto'; this.activeMode = ''; this.activeStride = 1;
      this.scale = 1; this.panX = 0; this.panY = 0; this.pointers = new Map(); this.touchOrigin = null; this.touchTap = null; this.onTouchTap = onTouchTap;
      this.video.addEventListener('timeupdate', () => { this.tryFinishTarget(); onTime(this, this.video.currentTime); });
      this.video.addEventListener('loadedmetadata', () => { if (this.target && !this.target.decoded) this.seek(this.target.seconds); this.publishStream(); });
      this.video.addEventListener('seeked', () => this.tryFinishTarget()); this.video.addEventListener('loadeddata', () => { this.tryFinishTarget(); this.publishStream(); }); this.video.addEventListener('resize', () => this.publishStream());
      this.video.addEventListener('canplay', () => { this.tryFinishTarget(); if (!this.target || this.target.decoded) this.setStatus(null); });
      this.video.addEventListener('progress', () => { if (this.status === 'waiting' && this.video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA && (!this.target || this.target.decoded)) this.setStatus(null); });
      this.video.addEventListener('playing', () => { if (!this.target || this.target.decoded) this.setStatus(null); });
      this.video.addEventListener('waiting', () => { if (this.range && (!this.target || !this.target.decoded || !this.video.paused)) this.setStatus('waiting'); }); this.video.addEventListener('error', () => { if (this.range) this.setStatus('error'); });
      this.video.addEventListener('ended', () => onEnded(this));
      element.addEventListener('dblclick', () => { if (!isTouchUi()) this.reset(); });
      element.addEventListener('click', (event) => { if (isTouchUi()) event.preventDefault(); });
      element.addEventListener('wheel', (event) => { event.preventDefault(); this.zoom(event.clientX, event.clientY, event.deltaY < 0 ? 1.15 : 1 / 1.15); }, { passive: false });
      element.addEventListener('pointerdown', (event) => this.pointerDown(event)); element.addEventListener('pointermove', (event) => this.pointerMove(event)); element.addEventListener('pointerup', (event) => this.pointerEnd(event)); element.addEventListener('pointercancel', (event) => this.pointerEnd(event));
    }
    setStatus(status) { if (status !== this.status) { this.status = status; this.onStatus(this, status); } }
    selectTarget(range, at, thumbnail, retainDecodedVideo = false, suppressPreview = false) { const retainVideo = retainDecodedVideo && this.target?.decoded; this.range = range; this.target = { rangeId: range.id, seconds: at, thumbnail, decoded: false, started: false }; if (!retainVideo && !suppressPreview) { this.showTargetPreview(this.target); this.setStatus('thumbnail'); } else this.setStatus('video'); return this.target; }
    captureFreeze() {
      if (!this.target?.decoded || this.video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || !this.video.videoWidth || !this.video.videoHeight) return false;
      try { this.freeze.width = this.video.videoWidth; this.freeze.height = this.video.videoHeight; this.freeze.getContext('2d').drawImage(this.video, 0, 0); this.freeze.hidden = false; return true; } catch (_error) { return false; }
    }
    setSource(range, at, autoplay, thumbnail, profile) {
      this.wantsPlayback = autoplay; const captured = this.captureFreeze(); this.destroy(); this.activeMode = profile.mode; this.activeStride = profile.stride; const target = this.selectTarget(range, at, thumbnail, false, captured);
      this.startSource(range, target, profile);
    }
    startSource(range, target, profile) {
      if (this.target !== target || target.started) return;
      if (!window.Hls && !window.timelapseHlsSettled) { hlsReady.then(() => this.startSource(range, target, profile)); return; }
      target.started = true;
      if (window.Hls && window.Hls.isSupported()) {
        const url = playlistPath(this.camera, range, profile, this.quality);
        const hls = this.hls = new window.Hls({ autoStartLoad: false, startLevel: 0, capLevelToPlayerSize: true, enableWorker: true, maxBufferLength: 5, maxMaxBufferLength: 5, maxBufferSize: 8 * 1024 * 1024, backBufferLength: 0 });
        hls.loadSource(url); hls.attachMedia(this.video);
        hls.on(window.Hls.Events.MANIFEST_PARSED, () => { const active = this.target; if (this.hls !== hls || !active || active.rangeId !== range.id) return; this.applyQuality(); this.updateCodec(hls.levels[0]); this.seek(active.seconds); if (this.wantsPlayback) { hls.startLoad(active.seconds); this.requestPlay(); } else this.prebufferHighest(active.seconds); });
        hls.on(window.Hls.Events.LEVEL_SWITCHED, (_event, data) => { if (this.hls === hls) this.updateCodec(hls.levels[data.level]); });
        const buffered = () => { if (this.hls === hls) this.releaseHighWhenBuffered(); };
        hls.on(window.Hls.Events.BUFFER_APPENDED, buffered); hls.on(window.Hls.Events.FRAG_BUFFERED, buffered);
        hls.on(window.Hls.Events.ERROR, (_event, data) => { if (this.hls === hls && data.fatal) { this.lockedHigh = false; this.setStatus('error'); } });
      } else if (this.video.canPlayType('application/vnd.apple.mpegurl')) {
        this.video.preload = 'auto'; this.video.addEventListener('loadedmetadata', () => { const active = this.target; if (!active || active.rangeId !== range.id) return; this.seek(active.seconds); if (this.wantsPlayback) this.play(); }, { once: true }); this.video.src = playlistPath(this.camera, range, profile, this.quality, profile.direct || this.quality !== 'auto'); this.video.load();
      } else this.setStatus('error');
    }
    seekTarget(range, at, thumbnail, retainDecodedVideo) { this.selectTarget(range, at, thumbnail, retainDecodedVideo); this.seek(at); }
    destroy() { if (this.hls) this.hls.destroy(); this.hls = null; this.lockedHigh = false; this.range = null; this.target = null; this.video.removeAttribute('src'); this.video.load(); }
    seek(time) { if (Number.isFinite(time)) { try { this.video.currentTime = Math.max(0, time); } catch (_error) { /* loadedmetadata will retry the latest target */ } } if (!this.target || !this.target.decoded) this.setStatus('video'); }
    bufferedAhead(time) { for (let index = 0; index < this.video.buffered.length; index += 1) if (time >= this.video.buffered.start(index) && time <= this.video.buffered.end(index)) return this.video.buffered.end(index) - time; return 0; }
    hasHighBuffer() { return this.target && this.bufferedAhead(this.target.seconds) >= 5 - 1 / FPS; }
    prebufferHighest(time) {
      if (!this.hls) return; const highest = this.hls.autoLevelCapping >= 0 ? this.hls.autoLevelCapping : this.hls.levels.length - 1;
      if (highest < 0) { this.hls.startLoad(time); return; }
      this.hls.stopLoad(); this.hls.loadLevel = highest; this.lockedHigh = true; this.hls.startLoad(time);
    }
    releaseHighWhenBuffered() { if (this.lockedHigh && this.hasHighBuffer()) { if (!this.wantsPlayback) this.hls.stopLoad(); this.releaseAbr(); } if (this.status === 'waiting') this.setStatus(this.target && !this.target.decoded ? 'video' : null); }
    releaseAbr() { if (this.hls && this.lockedHigh) this.hls.loadLevel = -1; this.lockedHigh = false; }
    requestPlay() { const target = this.target; this.video.play().catch(() => { if (this.wantsPlayback && this.target === target) this.setStatus('error'); }); }
    play() { this.wantsPlayback = true; const preserveHighBuffer = this.lockedHigh && this.hasHighBuffer(); if (this.hls && this.lockedHigh && !preserveHighBuffer) this.hls.stopLoad(); this.releaseAbr(); if (this.hls) this.hls.startLoad(this.video.currentTime); this.requestPlay(); }
    pause() { this.wantsPlayback = false; this.video.pause(); } stopLoading() { if (this.hls) this.hls.stopLoad(); }
    setSourceFps(sourceFps) { const rate = this.activeMode === 'exact' ? 1 : sourceFps / (FPS * this.activeStride); this.video.defaultPlaybackRate = rate; this.video.playbackRate = rate; }
    applyQuality() { if (!this.hls?.levels.length) return; const auto = this.quality === 'auto'; this.hls.autoLevelCapping = auto && this.camera === 'ptz' && isFirefoxMac() ? Math.max(0, this.hls.levels.length - 2) : -1; if (auto) this.hls.loadLevel = -1; else { const level = this.hls.levels.findIndex((entry) => entry.width === this.quality); if (level >= 0) this.hls.loadLevel = level; } }
    switchQuality(quality) { this.quality = quality; if (!this.hls || this.activeMode === 'exact') return false; this.applyQuality(); return true; }
    updateCodec(level) { if (level?.videoCodec) this.streamCodec = codecLabel(level.videoCodec); this.publishStream(); }
    publishStream() { const value = { codec: this.streamCodec, width: this.video.videoWidth, height: this.video.videoHeight }, key = `${value.codec}:${value.width}:${value.height}`; if (key !== this.streamKey) { this.streamKey = key; this.onStream(this, value); } }
    showPreview(thumbnail, high) { this.preview.onload = null; this.preview.onerror = null; this.preview.src = thumbnailPath(high ? 360 : 90, this.camera, thumbnail); this.preview.hidden = false; }
    showTargetPreview(target) {
      const promote = (height) => {
        if (this.target !== target || target.decoded) return; const src = thumbnailPath(height, this.camera, target.thumbnail);
        this.preview.onload = () => { if (this.target === target && !target.decoded && height === 90) preload(180); };
        this.preview.onerror = null; this.preview.src = src; this.preview.hidden = false;
      };
      const preload = (height) => {
        if (this.target !== target || target.decoded) return; const image = new Image(), src = thumbnailPath(height, this.camera, target.thumbnail);
        image.onload = () => { if (this.target !== target || target.decoded) return; this.preview.onload = () => { if (this.target === target && !target.decoded && height === 180) preload(360); }; this.preview.onerror = null; this.preview.src = src; };
        image.src = src;
      };
      this.preview.fetchPriority = 'high'; promote(90);
    }
    tryFinishTarget() {
      const target = this.target, tolerance = 2 / FPS;
      if (!target || target.decoded || this.video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || Math.abs(this.video.currentTime - target.seconds) > tolerance) return;
      if (this.video.requestVideoFrameCallback && !target.framePending) { target.framePending = true; this.video.requestVideoFrameCallback(() => { if (this.target === target) this.finishTarget(target); }); return; }
      this.finishTarget(target);
    }
    finishTarget(target) { target.decoded = true; if (this.target === target) { this.hidePreview(); this.hideFreeze(); this.setStatus(null); } }
    hidePreview() { this.preview.onload = null; this.preview.onerror = null; this.preview.hidden = true; this.preview.removeAttribute('src'); }
    hideFreeze() { this.freeze.hidden = true; this.freeze.getContext('2d').clearRect(0, 0, this.freeze.width, this.freeze.height); }
    reset() { this.scale = 1; this.panX = 0; this.panY = 0; this.paint(); }
    zoom(clientX, clientY, factor) { const next = clamp(this.scale * factor, 1, 4); if (next === this.scale) return; const rect = this.element.getBoundingClientRect(), x = clientX - rect.left - rect.width / 2, y = clientY - rect.top - rect.height / 2; this.panX = x - (x - this.panX) * next / this.scale; this.panY = y - (y - this.panY) * next / this.scale; this.scale = next; this.paint(); }
    pointerDown(event) { if (event.pointerType === 'touch') event.preventDefault(); this.element.setPointerCapture(event.pointerId); this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); if (event.pointerType === 'touch') { if (this.pointers.size === 1) this.touchTap = { id: event.pointerId, x: event.clientX, y: event.clientY, moved: false, multi: false }; else if (this.touchTap) this.touchTap.multi = true; const points = [...this.pointers.values()]; this.touchOrigin = { panX: this.panX, panY: this.panY, scale: this.scale, x: event.clientX, y: event.clientY, distance: points.length === 2 ? Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y) : 0 }; } }
    pointerMove(event) {
      if (event.pointerType !== 'touch' && this.scale > 1) { const rect = this.element.getBoundingClientRect(); this.panX = -(event.clientX - rect.left - rect.width / 2) * (this.scale - 1); this.panY = -(event.clientY - rect.top - rect.height / 2) * (this.scale - 1); this.paint(); return; }
      const previous = this.pointers.get(event.pointerId); if (!previous || !this.touchOrigin) return; if (this.touchTap?.id === event.pointerId && Math.hypot(event.clientX - this.touchTap.x, event.clientY - this.touchTap.y) > 12) this.touchTap.moved = true; this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); const points = [...this.pointers.values()];
      if (points.length === 2 && this.touchOrigin.distance) this.scale = clamp(this.touchOrigin.scale * Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y) / this.touchOrigin.distance, 1, 4);
      else if (this.scale > 1) { this.panX = this.touchOrigin.panX + event.clientX - this.touchOrigin.x; this.panY = this.touchOrigin.panY + event.clientY - this.touchOrigin.y; } this.paint();
    }
    pointerEnd(event) { const tap = event.type === 'pointerup' && event.pointerType === 'touch' && this.touchTap?.id === event.pointerId && !this.touchTap.moved && !this.touchTap.multi; this.pointers.delete(event.pointerId); this.touchOrigin = null; if (tap) { event.preventDefault(); this.onTouchTap(this, event); } if (!this.pointers.size) this.touchTap = null; }
    paint() { const rect = this.element.getBoundingClientRect(), x = rect.width * (this.scale - 1) / 2, y = rect.height * (this.scale - 1) / 2, transform = `translate(${clamp(this.panX, -x, x)}px,${clamp(this.panY, -y, y)}px) scale(${this.scale})`; this.panX = clamp(this.panX, -x, x); this.panY = clamp(this.panY, -y, y); this.video.style.transform = transform; this.freeze.style.transform = transform; this.preview.style.transform = transform; this.element.dataset.zoomed = this.scale > 1 ? 'true' : 'false'; }
  }

  fetch(archiveUrl('catalog.json')).then((response) => { if (!response.ok) throw new Error(`catalog.json: ${response.status}`); return response.json(); }).then(start).catch((error) => { root.innerHTML = renderError(error.message); });

  function start(catalog) {
    const cameras = catalog.cameras.map((camera) => typeof camera === 'string' ? camera : camera.id).slice(0, 2);
    const ranges = catalog.ranges.map((range) => ({ ...range, startMs: Date.parse(range.start), endMs: Date.parse(range.end) })).filter((range) => Number.isFinite(range.startMs) && Number.isFinite(range.endMs) && range.endMs > range.startMs).sort((left, right) => left.startMs - right.startMs);
    if (cameras.length < 2 || !ranges.length) throw new Error('Catalog needs two cameras and at least one range.');
    let total = 0; const spans = ranges.map((range) => { const frames = Math.max(1, Math.floor((range.endMs - range.startMs) / (FRAME_INTERVAL_SECONDS * 1000))), span = { range, first: total, frames }; total += frames; return span; });
    const firstMs = ranges[0].startMs, lastMs = ranges[ranges.length - 1].endMs - FRAME_INTERVAL_SECONDS * 1000;
    function slotForTime(time) { if (time <= firstMs) return 0; if (time >= lastMs) return total - 1; const span = spans.find((entry) => time >= entry.range.startMs && time < entry.range.endMs); return span ? span.first + clamp(Math.round((time - span.range.startMs) / (FRAME_INTERVAL_SECONDS * 1000)), 0, span.frames - 1) : (spans.find((entry) => entry.range.startMs > time)?.first ?? total - 1); }
    function choice(value) { const span = spans.find((entry) => value >= entry.first && value < entry.first + entry.frames) || spans[spans.length - 1], frame = clamp(value - span.first, 0, span.frames - 1); return { ...span, frame, sourceMs: span.range.startMs + frame * FRAME_INTERVAL_SECONDS * 1000 }; }
    const days = [], thumbnails = [];
    ranges.forEach((range) => {
      for (let day = dateKey(new Date(range.startMs)), last = dateKey(new Date(range.endMs - 1)); day <= last; day = addDays(day, 1)) {
        const noon = localNoon(day).getTime();
        if (noon >= range.startMs && noon < range.endMs) days.push({ day, slot: slotForTime(noon) });
      }
      for (let at = Math.ceil(range.startMs / THUMBNAIL_INTERVAL_MS) * THUMBNAIL_INTERVAL_MS; at < range.endMs; at += THUMBNAIL_INTERVAL_MS) thumbnails.push({ key: utcThumbnailKey(at), slot: slotForTime(at) });
    });
    const months = days.filter((item, index) => index === 0 || item.day.slice(0, 7) !== days[index - 1].day.slice(0, 7));
    const shortArchive = lastMs - firstMs <= 186 * 24 * 60 * 60 * 1000;
    root.innerHTML = renderWatch(cameras, total);
    const timeline = root.querySelector('#timeline'), timelineTrack = root.querySelector('.timeline-track'), scrubber = root.querySelector('#scrubber'), preview = root.querySelector('#timeline-preview'), hoverMarker = root.querySelector('#hover-marker'), hoverDate = root.querySelector('#hover-date'), play = root.querySelector('#play'), statuses = root.querySelector('#camera-statuses'), mediaSpeed = root.querySelector('.media-speed'), speedSlider = root.querySelector('.media-speed-slider'), speedControl = root.querySelector('.media-speed-control'), mobileSpeed = root.querySelector('#mobile-speed'), settings = root.querySelector('#settings'), speedMenu = root.querySelector('#speed-menu'), qualitySelects = [...root.querySelectorAll('.media-quality')], streamInfo = [...root.querySelectorAll('.media-stream-info')], outages = [...root.querySelectorAll('.outage')], paneStack = root.querySelector('.panes'), paneSplitter = root.querySelector('.pane-splitter'), seekFeedback = root.querySelector('#touch-seek-feedback'), mediaToggles = [...root.querySelectorAll('.media-toggle')], layout = root.querySelector('#layout'), fullscreen = root.querySelector('#fullscreen');
    function resizePanes(clientY) { const rect = paneStack.getBoundingClientRect(), split = clamp((clientY - rect.top) / rect.height, .15, .85); paneStack.style.gridTemplateRows = `${split}fr ${paneSplitter.offsetHeight}px ${1 - split}fr`; }
    paneSplitter.addEventListener('pointerdown', (event) => { event.preventDefault(); event.stopPropagation(); paneSplitter.setPointerCapture(event.pointerId); resizePanes(event.clientY); });
    paneSplitter.addEventListener('pointermove', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) { event.stopPropagation(); resizePanes(event.clientY); } });
    paneSplitter.addEventListener('pointerup', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) paneSplitter.releasePointerCapture(event.pointerId); });
    paneSplitter.addEventListener('pointercancel', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) paneSplitter.releasePointerCapture(event.pointerId); });
    const tickMap = new Map();
    months.forEach((item, index) => { const withYear = index === 0 || item.day.slice(5, 7) === '01'; tickMap.set(item.slot, { item, className: 'month', label: new Intl.DateTimeFormat('en-GB', { month: 'short', ...(withYear ? { year: '2-digit' } : {}), timeZone: TIME_ZONE }).format(localNoon(item.day)) }); });
    if (shortArchive) days.filter((_item, index) => index % 7 === 0).forEach((item) => { if (!tickMap.has(item.slot)) tickMap.set(item.slot, { item, className: 'week', label: item.day.slice(8) }); });
    root.querySelector('#ticks').innerHTML = [...tickMap.values()].sort((left, right) => left.item.slot - right.item.slot).map(({ item, className, label }) => `<span class="${className}" style="left:${total > 1 ? item.slot / (total - 1) * 100 : 0}%">${label}</span>`).join('');
    function hashTime() {
      const value = window.location.hash.slice(1);
      return /^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d+)?)?(?:Z|[+-]\d\d:\d\d)$/i.test(value) ? Date.parse(value) : NaN;
    }
    function sourceHash() { return `#${localTimestamp(choice(slot).sourceMs)}`; }
    function syncHash() { const hash = sourceHash(); if (window.location.hash !== hash) history.replaceState(history.state, '', hash); }
    const initialTime = hashTime();
    let slot = slotForTime(Number.isFinite(initialTime) ? initialTime : DEFAULT_SOURCE_TIME), loadedSource = '', loadedOutageRange = '', dragging = false, loadTimer = 0, hideTimer = 0, previewTimer = 0, speedTimer = 0, controlsTimer = 0, controlsRevealTimer = 0, mobileChromeTimer = 0, feedbackTimer = 0, renderedPreviewKey = '', pendingTarget = null, desiredPlaying = false, speedIndex = DEFAULT_SPEED_INDEX, sourceFps = SPEED_FPS[speedIndex], retainDecodedVideo = false, lastPaneTap = null, insetMode = false, insetPrimary = 0;
    const panes = cameras.map((camera) => new Pane(root.querySelector(`.pane[data-camera="${CSS.escape(camera)}"]`), camera, syncTime, syncEnded, renderCameraStatuses, renderStreamInfo, handlePaneTap));
    const outageTrack = document.createElement('track'); outageTrack.kind = 'metadata'; panes[0].video.append(outageTrack); outageTrack.track.mode = 'hidden';
    function renderOutage() { const seconds = choice(slot).frame / FPS, text = dragging ? '' : [...(outageTrack.track.cues || [])].filter((cue) => cue.startTime <= seconds && seconds < cue.endTime).map((cue) => cue.text).join('\n'); outages.forEach((outage) => { outage.textContent = text; outage.hidden = !text; }); }
    function loadOutages(range) { if (loadedOutageRange === range.id) return; loadedOutageRange = range.id; outages.forEach((outage) => { outage.hidden = true; }); outageTrack.src = archiveUrl(`subtitles/${range.id}.vtt`); outageTrack.track.mode = 'hidden'; }
    outageTrack.addEventListener('load', renderOutage);
    function renderCameraStatuses() { const text = { thumbnail: 'thumbnail…', video: 'video…', waiting: 'network…', error: 'failed' }; statuses.innerHTML = panes.filter((pane) => pane.status).map((pane) => `<span class="camera-status ${pane.status}">${html(cameraLabel(pane.camera))}: ${text[pane.status]}${pane.status === 'error' ? ` <button type="button" data-retry="${html(pane.camera)}">Retry</button>` : ''}</span>`).join(''); }
    function renderStreamInfo(pane, stream) { const resolution = stream.width && stream.height ? `${stream.width}×${stream.height}` : '—', text = `${cameraLabel(pane.camera)} · ${stream.codec} · ${resolution}`; streamInfo.filter((entry) => entry.dataset.streamCamera === pane.camera).forEach((entry) => { entry.textContent = text; }); }
    function thumbnailIndexFor(value) { return thumbnails.length ? thumbnails.reduce((best, thumbnail, index) => Math.abs(thumbnail.slot - value) < Math.abs(thumbnails[best].slot - value) ? index : best, 0) : -1; }
    function paintTimelinePreview(value = slot, fraction = total > 1 ? value / (total - 1) : 0) { const index = thumbnailIndexFor(value); if (index >= 0) { const key = thumbnails[index].key; if (key !== renderedPreviewKey) { renderedPreviewKey = key; preview.innerHTML = cameras.map((camera) => `<img alt="" src="${thumbnailPath(90, camera, key)}" srcset="${thumbnailPath(90, camera, key)} 1x, ${thumbnailPath(180, camera, key)} 2x, ${thumbnailPath(360, camera, key)} 4x">`).join(''); } const x = timelineTrack.offsetLeft + fraction * timelineTrack.clientWidth, half = Math.min(preview.offsetWidth / 2 + 2, timeline.clientWidth / 2); preview.style.setProperty('--preview-x', `${clamp(x, half, timeline.clientWidth - half)}px`); } }
    function hoverSlotAt(clientX) { const rect = timelineTrack.getBoundingClientRect(), fraction = clamp((clientX - rect.left) / rect.width, 0, 1), value = Math.round(fraction * (total - 1)), date = new Date(choice(value).sourceMs); hoverMarker.style.left = `${fraction * 100}%`; hoverDate.textContent = `${dateKey(date)} ${new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: TIME_ZONE }).format(date)}`; paintTimelinePreview(value, fraction); return value; }
    const HOVER_DISTANCE = 72;
    function distanceToRect(x, y, rect) { const dx = Math.max(rect.left - x, 0, x - rect.right), dy = Math.max(rect.top - y, 0, y - rect.bottom); return Math.hypot(dx, dy); }
    function showTimeline() { timeline.classList.add('active'); paintTimelinePreview(); window.clearTimeout(hideTimer); hideTimer = window.setTimeout(() => timeline.classList.remove('active'), 1300); }
    function showPointerTimeline(event) { if (distanceToRect(event.clientX, event.clientY, timelineTrack.getBoundingClientRect()) > HOVER_DISTANCE) { hidePointerTimeline(); return; } window.clearTimeout(hideTimer); timeline.classList.add('hovering'); hoverSlotAt(event.clientX); }
    function hidePointerTimeline() { timeline.classList.remove('hovering', 'active'); }
    function render() { scrubber.value = slot; syncHash(); renderOutage(); if (timeline.classList.contains('active')) paintTimelinePreview(); }
    function mediaSeconds(current, profile) { return Math.floor(current.frame / profile.stride) / FPS; }
    function quantizedSlot(profile) { const current = choice(slot); return current.first + Math.floor(current.frame / profile.stride) * profile.stride; }
    function activeProfile() { return desiredPlaying ? playbackProfile(sourceFps) : EXACT_PROFILE; }
    function armPending(current = choice(slot), profile = activeProfile()) { pendingTarget = { sourceKey: sourceKey(current.range, profile), seconds: mediaSeconds(current, profile), slot }; }
    function thumbnailFor(current) { const index = thumbnailIndexFor(slot); return index >= 0 ? thumbnails[index].key : utcThumbnailKey(current.sourceMs); }
    function load() {
      if (dragging) return;
      const current = choice(slot), profile = activeProfile(), key = sourceKey(current.range, profile), at = mediaSeconds(current, profile), thumbnail = thumbnailFor(current), retainVideo = retainDecodedVideo;
      retainDecodedVideo = false; armPending(current, profile); loadOutages(current.range);
      if (key !== loadedSource) { loadedSource = key; panes.forEach((pane) => { pane.setSource(current.range, at, desiredPlaying, thumbnail, profile); pane.setSourceFps(sourceFps); }); }
      else panes.forEach((pane) => { pane.seekTarget(current.range, at, thumbnail, retainVideo); pane.setSourceFps(sourceFps); if (desiredPlaying) pane.play(); else pane.prebufferHighest(at); });
    }
    function scheduleLoad(immediate) { window.clearTimeout(loadTimer); if (immediate) load(); else loadTimer = window.setTimeout(load, 250); }
    function showPanePreview() { const index = thumbnailIndexFor(slot); if (index < 0) return; const key = thumbnails[index].key; panes.forEach((pane) => pane.showPreview(key, false)); window.clearTimeout(previewTimer); previewTimer = window.setTimeout(() => { if (dragging) panes.forEach((pane) => pane.showPreview(key, true)); }, 180); }
    function setSlot(next, immediate = false, retainVideo = false) { slot = clamp(Math.round(next), 0, total - 1); if (desiredPlaying) slot = quantizedSlot(playbackProfile(sourceFps)); retainDecodedVideo = retainVideo; if (!dragging) armPending(); render(); if (dragging) showPanePreview(); else scheduleLoad(immediate); }
    function syncTime(source, seconds) {
      if (source !== panes[0] || dragging) return;
      if (pendingTarget) {
        if (loadedSource !== pendingTarget.sourceKey || Math.abs(seconds - pendingTarget.seconds) > 1 / FPS + .005) return;
        pendingTarget = null;
      }
      const current = choice(slot), next = current.first + clamp(Math.floor(seconds * FPS + .001) * source.activeStride, 0, current.frames - 1);
      if (next !== slot) { slot = next; render(); }
      panes.forEach((pane) => { if (pane !== source && Math.abs(pane.video.currentTime - seconds) > .05) pane.seek(seconds); });
    }
    function representedSlot() { const pane = panes[0], current = choice(slot); if (!pane.range || pane.range.id !== current.range.id || !Number.isFinite(pane.video.currentTime)) return slot; return current.first + clamp(Math.floor(pane.video.currentTime * FPS + .001) * pane.activeStride, 0, current.frames - 1); }
    function paintPlaying() { play.textContent = desiredPlaying ? 'Pause' : 'Play'; play.setAttribute('aria-label', desiredPlaying ? 'Pause' : 'Play'); mediaToggles.forEach((toggle) => { toggle.querySelector('[aria-hidden]').textContent = desiredPlaying ? '❚❚' : '▶'; toggle.querySelector('.media-toggle-label').textContent = desiredPlaying ? 'Pause' : 'Play'; toggle.setAttribute('aria-label', desiredPlaying ? 'Pause' : 'Play'); }); }
    function pauseAtSlot(next, retainVideo = false) { panes.forEach((pane) => pane.pause()); desiredPlaying = false; paintPlaying(); setSlot(next, true, retainVideo); }
    function setDesiredPlaying(next) {
      if (!next) { pauseAtSlot(representedSlot()); return; }
      desiredPlaying = true; slot = quantizedSlot(playbackProfile(sourceFps)); paintPlaying(); render(); load();
    }
    function setSpeedIndex(next) {
      const previousProfile = playbackProfile(sourceFps);
      speedIndex = clamp(Math.round(Number(next)), 0, SPEED_FPS.length - 1);
      sourceFps = SPEED_FPS[speedIndex];
      const nextProfile = playbackProfile(sourceFps);
      if (desiredPlaying && nextProfile.mode !== previousProfile.mode) { slot = quantizedSlot(nextProfile); render(); load(); }
      else if (desiredPlaying) panes.forEach((pane) => pane.setSourceFps(sourceFps));
      const label = formatSpeed(sourceFps);
      mediaSpeed.textContent = label;
      speedSlider.value = String(speedIndex);
      speedSlider.setAttribute('aria-valuetext', label);
      speedSlider.classList.toggle('native', NATIVE_SPEED_FPS.has(sourceFps));
      mobileSpeed.value = String(speedIndex);
      mobileSpeed.classList.toggle('native', NATIVE_SPEED_FPS.has(sourceFps));
      settings.setAttribute('aria-label', `Playback speed, ${label}`);
      mediaSpeed.classList.add('changed');
      window.clearTimeout(speedTimer);
      speedTimer = window.setTimeout(() => { mediaSpeed.classList.remove('changed'); }, 2000);
    }
    function syncEnded() { const current = choice(slot), index = spans.findIndex((span) => span.range.id === current.range.id), next = spans[index + 1]; if (!desiredPlaying || !next || panes[0].range?.id !== current.range.id) return; slot = next.first; loadedSource = ''; render(); load(); }
    function localOffset() { const source = choice(slot).sourceMs; return source - localNoon(dateKey(new Date(source))).getTime(); }
    function moveToDay(day) { setSlot(slotForTime(localNoon(day).getTime() + localOffset())); }
    function moveDays(amount) { moveToDay(addDays(dateKey(new Date(choice(slot).sourceMs)), amount)); }
    function beginScrub(event) { dragging = true; showMobileChrome(); outages.forEach((outage) => { outage.hidden = true; }); window.clearTimeout(loadTimer); panes.forEach((pane) => pane.stopLoading()); showPointerTimeline(event); showPanePreview(); if (event.pointerType === 'touch') scrubTouch(event); }
    function scrubTouch(event) { const next = hoverSlotAt(event.clientX); scrubber.value = String(next); showTimeline(); setSlot(next); }
    function endScrub(event) { if (!dragging || event.pointerType !== 'touch') return; scrubTouch(event); dragging = false; setSlot(Number(scrubber.value), true); showMobileChrome(); }
    scrubber.addEventListener('pointerdown', beginScrub);
    scrubber.addEventListener('pointermove', (event) => { if (dragging && event.pointerType === 'touch') scrubTouch(event); });
    scrubber.addEventListener('pointerup', endScrub); scrubber.addEventListener('pointercancel', endScrub);
    scrubber.addEventListener('input', () => { showTimeline(); setSlot(Number(scrubber.value)); });
    scrubber.addEventListener('change', () => { dragging = false; setSlot(Number(scrubber.value), true); });
    speedSlider.addEventListener('input', () => setSpeedIndex(speedSlider.value));
    qualitySelects.forEach((select) => select.addEventListener('change', () => {
      const pane = panes.find((entry) => entry.camera === select.dataset.qualityCamera), width = Number(select.value), quality = select.value === 'auto' ? 'auto' : qualityLadder(select.dataset.qualityCamera).some(([candidate]) => candidate === width) ? width : 'auto';
      if (!pane || pane.quality === quality) return;
      qualitySelects.filter((entry) => entry.dataset.qualityCamera === pane.camera).forEach((entry) => { entry.value = String(quality); });
      if (!pane.switchQuality(quality)) { const current = choice(slot), profile = activeProfile(); if (pane === panes[0]) armPending(current, profile); pane.setSource(current.range, mediaSeconds(current, profile), desiredPlaying, thumbnailFor(current), profile); pane.setSourceFps(sourceFps); }
      showMobileChrome();
    }));
    ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'dblclick', 'wheel'].forEach((type) => speedControl.addEventListener(type, (event) => { event.stopPropagation(); if (type === 'pointerdown') showMobileControls(speedControl.closest('.pane')); }));
    window.addEventListener('pointermove', showPointerTimeline);
    timeline.addEventListener('touchstart', (event) => { const touch = event.touches[0]; if (touch && event.target.closest('.timeline-track')) hoverSlotAt(touch.clientX); showTimeline(); showMobileChrome(); }, { passive: true });
    timeline.addEventListener('wheel', (event) => { event.preventDefault(); showPointerTimeline(event); const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY; if (delta) setSlot(slot + Math.sign(delta) * 240); }, { passive: false });
    function retryPane(camera) { const pane = panes.find((entry) => entry.camera === camera); if (!pane) return; const current = choice(slot), profile = activeProfile(); if (pane === panes[0]) armPending(current, profile); pane.setSource(current.range, mediaSeconds(current, profile), desiredPlaying, thumbnailFor(current), profile); pane.setSourceFps(sourceFps); }
    statuses.addEventListener('click', (event) => { const retry = event.target.closest('[data-retry]'); if (retry) retryPane(retry.dataset.retry); });
    play.addEventListener('click', () => { showMobileChrome(); setDesiredPlaying(!desiredPlaying); });
    function closeSpeedMenu() { timeline.classList.remove('speed-open'); settings.setAttribute('aria-expanded', 'false'); }
    function hideMobileChrome() { if (!isTouchUi()) return; window.clearTimeout(mobileChromeTimer); closeSpeedMenu(); root.classList.remove('mobile-chrome'); root.querySelectorAll('.pane.mobile-controls').forEach((entry) => entry.classList.remove('mobile-controls')); }
    function showMobileChrome() {
      if (!isTouchUi()) return;
      root.classList.add('mobile-chrome');
      window.clearTimeout(mobileChromeTimer);
      if (!dragging && !timeline.classList.contains('speed-open')) mobileChromeTimer = window.setTimeout(hideMobileChrome, 3000);
    }
    function showMobileControls(pane, delay = 0) { if (!isTouchUi() || !pane) return; window.clearTimeout(controlsTimer); window.clearTimeout(controlsRevealTimer); controlsRevealTimer = window.setTimeout(() => { root.querySelectorAll('.pane.mobile-controls').forEach((entry) => entry.classList.remove('mobile-controls')); pane.classList.add('mobile-controls'); showMobileChrome(); controlsTimer = window.setTimeout(() => pane.classList.remove('mobile-controls'), 2000); }, delay); }
    function showSeekFeedback(amount) { seekFeedback.textContent = amount < 0 ? '−10 h' : '+10 h'; seekFeedback.classList.add('active'); window.clearTimeout(feedbackTimer); feedbackTimer = window.setTimeout(() => seekFeedback.classList.remove('active'), 750); }
    function setInsetPrimary(pane) { insetPrimary = panes.indexOf(pane); panes.forEach((entry, index) => entry.element.classList.toggle('inset-primary', index === insetPrimary)); }
    function setInsetMode(next) { insetMode = next; paneStack.classList.toggle('inset', insetMode); layout.setAttribute('aria-pressed', String(insetMode)); layout.setAttribute('aria-label', insetMode ? 'Show stacked view' : 'Show inset view'); if (insetMode) setInsetPrimary(panes[insetPrimary]); }
    function handlePaneTap(pane, event) {
      if (!isTouchUi()) return;
      if (insetMode && !pane.element.classList.contains('inset-primary')) { setInsetPrimary(pane); showMobileControls(pane.element); return; }
      const now = performance.now(), repeated = lastPaneTap && lastPaneTap.pane === pane && now - lastPaneTap.at < 320 && Math.hypot(event.clientX - lastPaneTap.x, event.clientY - lastPaneTap.y) < 48;
      window.clearTimeout(controlsRevealTimer);
      if (repeated) { const rect = pane.element.getBoundingClientRect(), amount = event.clientX < rect.left + rect.width / 2 ? -120 : 120; showMobileControls(pane.element); setSlot(slot + amount, true); showSeekFeedback(amount); lastPaneTap = null; }
      else { const wasVisible = root.classList.contains('mobile-chrome'); lastPaneTap = { pane, at: now, x: event.clientX, y: event.clientY }; controlsRevealTimer = window.setTimeout(() => { lastPaneTap = null; if (wasVisible) hideMobileChrome(); else showMobileControls(pane.element); }, 320); }
    }
    layout.addEventListener('click', () => { showMobileChrome(); setInsetMode(!insetMode); });
    panes.forEach((pane) => pane.element.addEventListener('pointerup', (event) => { if (event.pointerType !== 'touch' && insetMode && !pane.element.classList.contains('inset-primary') && !event.target.closest('button, input')) setInsetPrimary(pane); }));
    mediaToggles.forEach((toggle) => { const pane = toggle.closest('.pane'); ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'dblclick'].forEach((type) => toggle.addEventListener(type, (event) => event.stopPropagation())); toggle.addEventListener('click', (event) => { event.stopPropagation(); showMobileControls(pane); setDesiredPlaying(!desiredPlaying); }); });
    settings.addEventListener('click', (event) => { event.stopPropagation(); const open = !timeline.classList.contains('speed-open'); closeSpeedMenu(); if (open) { timeline.classList.add('speed-open'); settings.setAttribute('aria-expanded', 'true'); } showMobileChrome(); });
    speedMenu.addEventListener('click', (event) => event.stopPropagation());
    mobileSpeed.addEventListener('change', () => { setSpeedIndex(mobileSpeed.value); closeSpeedMenu(); showMobileChrome(); });
    function toggleFullscreen() { if (document.fullscreenElement) document.exitFullscreen(); else if (root.requestFullscreen) root.requestFullscreen().catch(() => undefined); else if (panes[0].video.webkitEnterFullscreen) panes[0].video.webkitEnterFullscreen(); }
    fullscreen.hidden = !(document.fullscreenEnabled || root.requestFullscreen || panes[0].video.webkitEnterFullscreen);
    fullscreen.addEventListener('click', () => { showMobileChrome(); toggleFullscreen(); });
    window.addEventListener('hashchange', () => { const time = hashTime(); if (Number.isFinite(time)) pauseAtSlot(slotForTime(time)); });
    function stepFrames(amount) { pauseAtSlot(representedSlot() + amount, true); }
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') return;
      const key = event.key, horizontal = key === 'ArrowLeft' ? -1 : key === 'ArrowRight' ? 1 : 0, vertical = key === 'ArrowUp' ? 1 : key === 'ArrowDown' ? -1 : 0, page = key === 'PageUp' ? 1 : key === 'PageDown' ? -1 : 0;
      if ([speedSlider, mobileSpeed].includes(event.target) && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown'].includes(key)) return;
      if (key === ',' || key === '.') { event.preventDefault(); stepFrames(key === ',' ? -1 : 1); }
      else if (horizontal) { event.preventDefault(); if (event.metaKey || event.ctrlKey) stepFrames(horizontal); else setSlot(slot + horizontal * (event.shiftKey ? 24 : 120)); }
      else if (vertical) { event.preventDefault(); setSlot(slot + vertical * (event.shiftKey ? 120 : 1440)); }
      else if (page) { event.preventDefault(); moveDays(page * (event.shiftKey ? 50 : 1)); }
      else if (key === ' ' || key.toLowerCase() === 'p') { event.preventDefault(); play.click(); }
      else if (key === '[' || key === ']') { event.preventDefault(); setSpeedIndex(speedIndex + (key === '[' ? -1 : 1)); }
      else if (key === 'Home') { event.preventDefault(); setSlot(0); }
      else if (key === 'End') { event.preventDefault(); setSlot(total - 1); }
      else if (key.toLowerCase() === 'f') toggleFullscreen();
    });
    render(); load(); showMobileChrome();
  }
})();

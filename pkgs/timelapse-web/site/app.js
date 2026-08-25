(() => {
  'use strict';
  const FPS = 24, SPEED_FPS = [2, 4, 6, 12, 24, 36, 48, 72, 96, 144, 288, 576, 864, 1152, 1728], NATIVE_SPEED_FPS = new Set([24, 144, 864]), DEFAULT_SPEED_INDEX = SPEED_FPS.indexOf(FPS), FRAME_INTERVAL_SECONDS = 300, THUMBNAIL_INTERVAL_MS = 6 * 60 * 60 * 1000, BUFFER_SECONDS = 15, SEEK_EPSILON = .01, TIME_ZONE = 'Europe/Vilnius';
  const DEFAULT_SOURCE_TIME = Date.parse('2025-03-18T06:00:00Z');
  const root = document.querySelector('#app');
  const archiveUrl = (path) => new URL(path, location.origin + location.pathname).href;
  const partsFormat = new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const isTouchUi = () => window.matchMedia('(any-pointer: coarse), (max-width: 700px)').matches;
  function playbackProfile(sourceFps) {
    if (sourceFps <= 24) return { mode: 'x1', stride: 1 };
    if (sourceFps <= 288) return { mode: 'x6', stride: 6 };
    return { mode: 'x36', stride: 36 };
  }
  const sourceKey = (range, profile) => `${range.id}:${profile.mode}`;
  const pathPart = (value) => encodeURIComponent(value);
  const rangeUrl = (range, path) => archiveUrl(`ranges/${pathPart(range.id)}/${path}`);
  const playlistPath = (camera, range, profile) => {
    const base = `video/${pathPart(camera)}-${pathPart(range.id)}`, modeBase = profile.mode === 'x1' ? base : `${base}/${profile.mode}`;
    return rangeUrl(range, `${modeBase}/stream.m3u8`);
  };
  const thumbnailPath = (height, camera, thumbnail) => rangeUrl(thumbnail.range, `thumbnails/h${height}/${pathPart(camera)}-${pathPart(thumbnail.key)}.jpg`);
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
  function renderStreamControl(camera) { return `<span class="media-stream media-stream-info" data-stream-camera="${html(camera)}">${html(cameraLabel(camera))} · AV1 · —</span>`; }
  function renderShortcutHelp() {
    return `<aside class="shortcut-help" aria-label="Keyboard navigation"><strong>Source-time keys</strong><dl><dt>, . · ⌘/Ctrl←→</dt><dd>frame − / + · pause</dd><dt>← / →</dt><dd>− / + 10 h</dd><dt>Shift← / →</dt><dd>− / + 2 h</dd><dt>↓ / ↑</dt><dd>− / + 5 d</dd><dt>Shift↓ / ↑</dt><dd>− / + 10 h</dd><dt>PgDn / PgUp</dt><dd>day − / +</dd><dt>Shift PgDn / PgUp</dt><dd>− / + 50 d</dd><dt>Timeline wheel</dt><dd>− / + 20 h</dd><dt>Space / P</dt><dd>play / pause</dd><dt>[ / ]</dt><dd>slower / faster</dd><dt>Home / End</dt><dd>first / last</dd><dt>F</dt><dd>fullscreen</dd></dl></aside>`;
  }
  function renderPane(camera, cameras) {
    const ptzChrome = cameras.length === 1 || camera === 'ptz' ? `<div class="media-speed-control"><div class="media-streams">${cameras.map(renderStreamControl).join('')}</div><output class="media-speed" aria-label="Current playback speed">${formatSpeed(FPS)}</output><input class="media-speed-slider" type="range" min="0" max="${SPEED_FPS.length - 1}" step="1" value="${DEFAULT_SPEED_INDEX}" aria-label="Playback speed" aria-valuetext="${html(formatSpeed(FPS))}"></div>${renderShortcutHelp()}` : '';
    return `<section class="pane" data-camera="${html(camera)}"><div class="media"><video muted playsinline preload="none" disablePictureInPicture></video><div class="buffer-indicator" role="status" aria-live="polite" aria-atomic="true" hidden><span class="buffer-spinner" aria-hidden="true"></span><span class="buffer-label">buffering…</span></div><p class="outage" hidden></p><button class="media-toggle" type="button" aria-label="Play"><span aria-hidden="true">▶</span><span class="media-toggle-label">Play</span></button>${ptzChrome}</div></section>`;
  }
  function renderSpeedOptions() { return SPEED_FPS.map((fps, index) => `<option value="${index}"${index === DEFAULT_SPEED_INDEX ? ' selected' : ''}>${html(formatSpeed(fps))}</option>`).join(''); }
  function renderTimeline(total, cameras) {
    return `<aside id="timeline" class="timeline" aria-label="Archive timeline"><button id="play" class="timeline-play" type="button" aria-label="Play">Play</button><div class="timeline-track"><input id="scrubber" type="range" min="0" max="${total - 1}" value="0" step="1" aria-label="Browse every five minutes"><div id="ticks" class="ticks"></div><div id="hover-marker" class="hover-marker"><span id="hover-date"></span></div></div><div id="timeline-preview" class="timeline-preview" aria-hidden="true"></div><button id="layout" class="timeline-button" type="button" aria-label="Show inset view" aria-pressed="false">▣</button><button id="settings" class="timeline-button mobile-only" type="button" aria-label="Playback speed, ${html(formatSpeed(FPS))}" aria-expanded="false" aria-controls="speed-menu">⚙</button><div id="speed-menu" class="speed-menu mobile-only" role="group" aria-label="Playback options"><div class="mobile-streams">${cameras.map(renderStreamControl).join('')}</div><label for="mobile-speed">Playback speed</label><select id="mobile-speed">${renderSpeedOptions()}</select></div><button id="fullscreen" class="timeline-button" type="button" aria-label="Fullscreen">⛶</button></aside>`;
  }
  function renderWatch(cameras, total, label) {
    return `<section class="watch">${label ? `<p class="archive-label">${html(label)}</p>` : ''}<div class="panes${cameras.length === 1 ? ' single' : ''}">${cameras.map((camera) => renderPane(camera, cameras)).join('<div class="pane-splitter" aria-label="Resize panes"></div>')}</div>${renderTimeline(total, cameras)}<div id="camera-statuses" class="camera-statuses" aria-live="polite"></div><output id="touch-seek-feedback" class="touch-seek-feedback" aria-live="polite"></output></section>`;
  }
  function renderError(message) { return `<p class="error">Could not open the archive: ${html(message)}</p>`; }
  function renderPreparing() { return '<p class="preparing">Archive is being prepared…</p>'; }

  class Pane {
    constructor(element, onTime, onEnded, onStatus, onStream, onTouchTap) {
      this.element = element; this.video = element.querySelector('video'); this.hls = null; this.onStatus = onStatus; this.onStream = onStream;
      this.scale = 1; this.panX = 0; this.panY = 0; this.pointers = new Map(); this.touchOrigin = null; this.touchTap = null; this.onTouchTap = onTouchTap;
      this.video.addEventListener('timeupdate', () => onTime(this, this.video.currentTime));
      this.video.addEventListener('loadedmetadata', () => { const at = Number(this.video.dataset.startPosition); if (Number.isFinite(at) && Math.abs(this.video.currentTime - at) > .05) this.seek(at); this.publishStream(); });
      this.video.addEventListener('loadeddata', () => this.publishStream()); this.video.addEventListener('resize', () => this.publishStream());
      const ready = () => { if (this.element.dataset.sourceKey) this.setStatus(''); }; this.video.addEventListener('canplay', ready); this.video.addEventListener('playing', ready);
      this.video.addEventListener('waiting', () => { if (!this.video.paused) this.setStatus('waiting'); }); this.video.addEventListener('error', () => { if (this.element.dataset.sourceKey) this.fail(); });
      this.video.addEventListener('ended', () => onEnded(this));
      element.addEventListener('dblclick', () => { if (!isTouchUi()) this.reset(); });
      element.addEventListener('click', (event) => { if (isTouchUi()) event.preventDefault(); });
      element.addEventListener('wheel', (event) => { event.preventDefault(); this.zoom(event.clientX, event.clientY, event.deltaY < 0 ? 1.15 : 1 / 1.15); }, { passive: false });
      element.addEventListener('pointerdown', (event) => this.pointerDown(event)); element.addEventListener('pointermove', (event) => this.pointerMove(event)); element.addEventListener('pointerup', (event) => this.pointerEnd(event)); element.addEventListener('pointercancel', (event) => this.pointerEnd(event));
    }
    setStatus(status) { this.element.querySelector('.buffer-indicator').hidden = status !== 'waiting'; if (status === this.element.dataset.status) return; this.element.dataset.status = status; this.onStatus(); }
    fail() { this.destroy(); this.setStatus('error'); }
    setSource(key, url, at, autoplay) {
      this.destroy(); this.element.dataset.sourceKey = key; this.video.dataset.startPosition = String(at); this.video.autoplay = autoplay; this.setStatus('video');
      if (window.Hls && window.Hls.isSupported()) {
        const hls = this.hls = new window.Hls({ startPosition: at, maxBufferLength: BUFFER_SECONDS, maxMaxBufferLength: BUFFER_SECONDS, backBufferLength: 0 });
        hls.loadSource(url); hls.attachMedia(this.video);
        hls.on(window.Hls.Events.ERROR, (_event, data) => { if (this.hls === hls && data.fatal) this.fail(); });
      } else if (this.video.canPlayType('application/vnd.apple.mpegurl')) {
        this.video.preload = 'auto'; this.video.src = url; this.video.load();
      } else this.fail();
    }
    destroy() { const hls = this.hls; this.hls = null; try { hls?.destroy(); } finally { delete this.element.dataset.sourceKey; delete this.video.dataset.startPosition; this.setStatus(''); this.video.removeAttribute('src'); this.video.load(); } }
    seek(time) { this.video.dataset.startPosition = String(time); try { this.video.currentTime = Math.max(0, time + SEEK_EPSILON); } catch (_error) { /* loadedmetadata retries the latest position */ } }
    play() { this.video.autoplay = true; this.video.play().catch(() => undefined); }
    pause() { this.video.autoplay = false; this.setStatus(''); this.video.pause(); }
    setRate(rate) { this.video.defaultPlaybackRate = rate; this.video.playbackRate = rate; }
    publishStream() { this.onStream(this, { codec: 'AV1', width: this.video.videoWidth, height: this.video.videoHeight }); }
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
    paint() { const rect = this.element.getBoundingClientRect(), x = rect.width * (this.scale - 1) / 2, y = rect.height * (this.scale - 1) / 2, transform = `translate(${clamp(this.panX, -x, x)}px,${clamp(this.panY, -y, y)}px) scale(${this.scale})`; this.panX = clamp(this.panX, -x, x); this.panY = clamp(this.panY, -y, y); this.video.style.transform = transform; this.element.dataset.zoomed = this.scale > 1 ? 'true' : 'false'; }
  }

  function loadCatalog() {
    fetch(archiveUrl('catalog.json'), { cache: 'no-store' }).then((response) => {
      if (response.status === 404) { root.innerHTML = renderPreparing(); window.setTimeout(loadCatalog, 3000); return null; }
      if (!response.ok) throw new Error(`catalog.json: ${response.status}`);
      return response.json();
    }).then((catalog) => { if (!catalog) return; if (!catalog.ranges?.length) { root.innerHTML = renderPreparing(); window.setTimeout(loadCatalog, 3000); return; } start(catalog); }).catch((error) => { root.innerHTML = renderError(error.message); });
  }
  loadCatalog();

  function start(catalog) {
    const cameras = catalog.cameras.map((camera) => typeof camera === 'string' ? camera : camera.id).slice(0, 2);
    const ranges = catalog.ranges.map((range) => ({ ...range, startMs: Date.parse(range.start), endMs: Date.parse(range.end) })).filter((range) => Number.isFinite(range.startMs) && Number.isFinite(range.endMs) && range.endMs > range.startMs).sort((left, right) => left.startMs - right.startMs);
    if (!cameras.length || !ranges.length) throw new Error('Catalog needs at least one camera and one range.');
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
      for (let at = Math.ceil(range.startMs / THUMBNAIL_INTERVAL_MS) * THUMBNAIL_INTERVAL_MS; at < range.endMs; at += THUMBNAIL_INTERVAL_MS) thumbnails.push({ key: utcThumbnailKey(at), range, slot: slotForTime(at) });
    });
    const months = days.filter((item, index) => index === 0 || item.day.slice(0, 7) !== days[index - 1].day.slice(0, 7));
    const shortArchive = lastMs - firstMs <= 186 * 24 * 60 * 60 * 1000;
    root.innerHTML = renderWatch(cameras, total, catalog.label);
    const timeline = root.querySelector('#timeline'), timelineTrack = root.querySelector('.timeline-track'), scrubber = root.querySelector('#scrubber'), preview = root.querySelector('#timeline-preview'), hoverMarker = root.querySelector('#hover-marker'), hoverDate = root.querySelector('#hover-date'), play = root.querySelector('#play'), statuses = root.querySelector('#camera-statuses'), mediaSpeed = root.querySelector('.media-speed'), speedSlider = root.querySelector('.media-speed-slider'), speedControl = root.querySelector('.media-speed-control'), mobileSpeed = root.querySelector('#mobile-speed'), settings = root.querySelector('#settings'), speedMenu = root.querySelector('#speed-menu'), streamInfo = [...root.querySelectorAll('.media-stream-info')], outages = [...root.querySelectorAll('.outage')], paneStack = root.querySelector('.panes'), paneSplitter = root.querySelector('.pane-splitter'), seekFeedback = root.querySelector('#touch-seek-feedback'), mediaToggles = [...root.querySelectorAll('.media-toggle')], layout = root.querySelector('#layout'), fullscreen = root.querySelector('#fullscreen');
    function resizePanes(clientY) { const rect = paneStack.getBoundingClientRect(), split = clamp((clientY - rect.top) / rect.height, .15, .85); paneStack.style.gridTemplateRows = `${split}fr ${paneSplitter.offsetHeight}px ${1 - split}fr`; }
    if (paneSplitter) {
      paneSplitter.addEventListener('pointerdown', (event) => { event.preventDefault(); event.stopPropagation(); paneSplitter.setPointerCapture(event.pointerId); resizePanes(event.clientY); });
      paneSplitter.addEventListener('pointermove', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) { event.stopPropagation(); resizePanes(event.clientY); } });
      paneSplitter.addEventListener('pointerup', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) paneSplitter.releasePointerCapture(event.pointerId); });
      paneSplitter.addEventListener('pointercancel', (event) => { if (paneSplitter.hasPointerCapture(event.pointerId)) paneSplitter.releasePointerCapture(event.pointerId); });
    }
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
    let slot = slotForTime(Number.isFinite(initialTime) ? initialTime : DEFAULT_SOURCE_TIME), loadedSource = '', loadedOutageRange = '', dragging = false, hideTimer = 0, speedTimer = 0, controlsTimer = 0, controlsRevealTimer = 0, mobileChromeTimer = 0, feedbackTimer = 0, renderedPreviewKey = '', desiredPlaying = false, speedIndex = DEFAULT_SPEED_INDEX, lastPaneTap = null, insetMode = false, insetPrimary = 0;
    const panes = cameras.map((camera) => new Pane(root.querySelector(`.pane[data-camera="${CSS.escape(camera)}"]`), syncTime, syncEnded, renderCameraStatuses, renderStreamInfo, handlePaneTap));
    const outageTrack = document.createElement('track'); outageTrack.kind = 'metadata'; panes[0].video.append(outageTrack); outageTrack.track.mode = 'hidden';
    function renderOutage() { const seconds = choice(slot).frame / FPS, text = dragging ? '' : [...(outageTrack.track.cues || [])].filter((cue) => cue.startTime <= seconds && seconds < cue.endTime).map((cue) => cue.text).join('\n'); outages.forEach((outage) => { outage.textContent = text; outage.hidden = !text; }); }
    function loadOutages(range) { if (loadedOutageRange === range.id) return; loadedOutageRange = range.id; outages.forEach((outage) => { outage.hidden = true; }); outageTrack.src = rangeUrl(range, `subtitles/${pathPart(range.id)}.vtt`); outageTrack.track.mode = 'hidden'; }
    outageTrack.addEventListener('load', renderOutage);
    function renderCameraStatuses() { const text = { video: 'video…', waiting: 'buffering…', error: 'failed' }; statuses.innerHTML = panes.map((pane) => ({ pane, status: pane.element.dataset.status })).filter(({ status }) => status).map(({ pane, status }) => { const camera = pane.element.dataset.camera; return `<span class="camera-status ${status}">${html(cameraLabel(camera))}: ${text[status]}${status === 'error' ? ` <button type="button" data-retry="${html(camera)}">Retry</button>` : ''}</span>`; }).join(''); }
    function renderStreamInfo(pane, stream) { const camera = pane.element.dataset.camera, resolution = stream.width && stream.height ? `${stream.width}×${stream.height}` : '—', text = `${cameraLabel(camera)} · ${stream.codec} · ${resolution}`; streamInfo.filter((entry) => entry.dataset.streamCamera === camera).forEach((entry) => { entry.textContent = text; }); }
    function thumbnailIndexFor(value) { return thumbnails.length ? thumbnails.reduce((best, thumbnail, index) => Math.abs(thumbnail.slot - value) < Math.abs(thumbnails[best].slot - value) ? index : best, 0) : -1; }
    function paintTimelinePreview(value = slot, fraction = total > 1 ? value / (total - 1) : 0) { const index = thumbnailIndexFor(value); if (index >= 0) { const thumbnail = thumbnails[index], key = `${thumbnail.range.id}:${thumbnail.key}`; if (key !== renderedPreviewKey) { renderedPreviewKey = key; preview.innerHTML = cameras.map((camera) => `<img alt="" src="${thumbnailPath(90, camera, thumbnail)}" srcset="${thumbnailPath(90, camera, thumbnail)} 1x, ${thumbnailPath(180, camera, thumbnail)} 2x, ${thumbnailPath(360, camera, thumbnail)} 4x">`).join(''); } const x = timelineTrack.offsetLeft + fraction * timelineTrack.clientWidth, half = Math.min(preview.offsetWidth / 2 + 2, timeline.clientWidth / 2); preview.style.setProperty('--preview-x', `${clamp(x, half, timeline.clientWidth - half)}px`); } }
    function hoverSlotAt(clientX) { const rect = timelineTrack.getBoundingClientRect(), fraction = clamp((clientX - rect.left) / rect.width, 0, 1), value = Math.round(fraction * (total - 1)), date = new Date(choice(value).sourceMs); hoverMarker.style.left = `${fraction * 100}%`; hoverDate.textContent = `${dateKey(date)} ${new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: TIME_ZONE }).format(date)}`; paintTimelinePreview(value, fraction); return value; }
    const HOVER_DISTANCE = 72;
    function distanceToRect(x, y, rect) { const dx = Math.max(rect.left - x, 0, x - rect.right), dy = Math.max(rect.top - y, 0, y - rect.bottom); return Math.hypot(dx, dy); }
    function showTimeline() { timeline.classList.add('active'); paintTimelinePreview(); window.clearTimeout(hideTimer); hideTimer = window.setTimeout(() => timeline.classList.remove('active'), 1300); }
    function showPointerTimeline(event) { if (distanceToRect(event.clientX, event.clientY, timelineTrack.getBoundingClientRect()) > HOVER_DISTANCE) { hidePointerTimeline(); return; } window.clearTimeout(hideTimer); timeline.classList.add('hovering'); hoverSlotAt(event.clientX); }
    function hidePointerTimeline() { timeline.classList.remove('hovering', 'active'); }
    function render() { scrubber.value = slot; syncHash(); renderOutage(); if (timeline.classList.contains('active')) paintTimelinePreview(); }
    function mediaSeconds(current, profile) { return Math.floor(current.frame / profile.stride) / FPS; }
    function quantizedSlot(profile) { const current = choice(slot); return current.first + Math.floor(current.frame / profile.stride) * profile.stride; }
    function activeFps() { return SPEED_FPS[speedIndex]; }
    function activeProfile() { return playbackProfile(activeFps()); }
    function load() {
      if (dragging) return;
      const current = choice(slot), profile = activeProfile(), key = sourceKey(current.range, profile), at = mediaSeconds(current, profile), rate = activeFps() / (FPS * profile.stride);
      loadOutages(current.range);
      panes.forEach((pane) => pane.setRate(rate));
      if (key !== loadedSource) { loadedSource = key; panes.forEach((pane) => pane.setSource(key, playlistPath(pane.element.dataset.camera, current.range, profile), at, desiredPlaying)); }
      else panes.forEach((pane) => { pane.seek(at); if (desiredPlaying) pane.play(); });
    }
    function setSlot(next) { slot = clamp(Math.round(next), 0, total - 1); if (desiredPlaying) slot = quantizedSlot(activeProfile()); render(); if (!dragging) load(); }
    function syncTime(source, seconds) {
      if (source !== panes[0] || dragging || source.element.dataset.sourceKey !== loadedSource) return;
      const requested = Number(source.video.dataset.startPosition); if (Number.isFinite(requested)) { if (Math.abs(seconds - requested) > 1 / FPS + .005) return; delete source.video.dataset.startPosition; }
      const current = choice(slot), stride = activeProfile().stride, next = current.first + clamp(Math.floor(seconds * FPS + .001) * stride, 0, current.frames - 1);
      if (next !== slot) { slot = next; render(); }
      panes.forEach((pane) => { if (pane !== source && Math.abs(pane.video.currentTime - seconds) > .05) pane.seek(seconds); });
    }
    function representedSlot() { const pane = panes[0], current = choice(slot), profile = activeProfile(); if (pane.video.dataset.startPosition !== undefined || pane.element.dataset.sourceKey !== sourceKey(current.range, profile) || !Number.isFinite(pane.video.currentTime)) return slot; return current.first + clamp(Math.floor(pane.video.currentTime * FPS + .001) * profile.stride, 0, current.frames - 1); }
    function paintPlaying() { play.textContent = desiredPlaying ? 'Pause' : 'Play'; play.setAttribute('aria-label', desiredPlaying ? 'Pause' : 'Play'); mediaToggles.forEach((toggle) => { toggle.querySelector('[aria-hidden]').textContent = desiredPlaying ? '❚❚' : '▶'; toggle.querySelector('.media-toggle-label').textContent = desiredPlaying ? 'Pause' : 'Play'; toggle.setAttribute('aria-label', desiredPlaying ? 'Pause' : 'Play'); }); }
    function pauseAtSlot(next) { panes.forEach((pane) => pane.pause()); desiredPlaying = false; paintPlaying(); setSlot(next); }
    function setDesiredPlaying(next) {
      if (!next) { panes.forEach((pane) => pane.pause()); desiredPlaying = false; slot = representedSlot(); paintPlaying(); render(); return; }
      desiredPlaying = true; slot = quantizedSlot(activeProfile()); paintPlaying(); render(); load();
    }
    function setSpeedIndex(next) {
      const previousProfile = activeProfile();
      speedIndex = clamp(Math.round(Number(next)), 0, SPEED_FPS.length - 1);
      const sourceFps = activeFps(), nextProfile = activeProfile();
      if (nextProfile.mode !== previousProfile.mode) { slot = quantizedSlot(nextProfile); render(); load(); }
      else panes.forEach((pane) => pane.setRate(sourceFps / (FPS * nextProfile.stride)));
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
    function syncEnded(source) { const current = choice(slot), index = spans.findIndex((span) => span.range.id === current.range.id), next = spans[index + 1]; if (source !== panes[0] || !desiredPlaying || source.element.dataset.sourceKey !== loadedSource) return; if (!next) { setDesiredPlaying(false); return; } slot = next.first; loadedSource = ''; render(); load(); }
    function localOffset() { const source = choice(slot).sourceMs; return source - localNoon(dateKey(new Date(source))).getTime(); }
    function moveToDay(day) { setSlot(slotForTime(localNoon(day).getTime() + localOffset())); }
    function moveDays(amount) { moveToDay(addDays(dateKey(new Date(choice(slot).sourceMs)), amount)); }
    function beginScrub(event) { dragging = true; showMobileChrome(); outages.forEach((outage) => { outage.hidden = true; }); showPointerTimeline(event); if (event.pointerType === 'touch') scrubTouch(event); }
    function scrubTouch(event) { const next = hoverSlotAt(event.clientX); scrubber.value = String(next); showTimeline(); setSlot(next); }
    function endScrub(event) { if (!dragging || event.pointerType !== 'touch') return; scrubTouch(event); dragging = false; setSlot(Number(scrubber.value)); showMobileChrome(); }
    scrubber.addEventListener('pointerdown', beginScrub);
    scrubber.addEventListener('pointermove', (event) => { if (dragging && event.pointerType === 'touch') scrubTouch(event); });
    scrubber.addEventListener('pointerup', endScrub); scrubber.addEventListener('pointercancel', endScrub);
    scrubber.addEventListener('input', () => { showTimeline(); setSlot(Number(scrubber.value)); });
    scrubber.addEventListener('change', () => { dragging = false; setSlot(Number(scrubber.value)); });
    speedSlider.addEventListener('input', () => setSpeedIndex(speedSlider.value));
    ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'dblclick', 'wheel'].forEach((type) => speedControl.addEventListener(type, (event) => { event.stopPropagation(); if (type === 'pointerdown') showMobileControls(speedControl.closest('.pane')); }));
    window.addEventListener('pointermove', showPointerTimeline);
    timeline.addEventListener('touchstart', (event) => { const touch = event.touches[0]; if (touch && event.target.closest('.timeline-track')) hoverSlotAt(touch.clientX); showTimeline(); showMobileChrome(); }, { passive: true });
    timeline.addEventListener('wheel', (event) => { event.preventDefault(); showPointerTimeline(event); const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY; if (delta) setSlot(slot + Math.sign(delta) * 240); }, { passive: false });
    function retryPane(camera) { const pane = panes.find((entry) => entry.element.dataset.camera === camera); if (!pane) return; const current = choice(slot), profile = activeProfile(), key = sourceKey(current.range, profile); pane.setSource(key, playlistPath(camera, current.range, profile), mediaSeconds(current, profile), desiredPlaying); pane.setRate(activeFps() / (FPS * profile.stride)); }
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
      if (repeated) { const rect = pane.element.getBoundingClientRect(), amount = event.clientX < rect.left + rect.width / 2 ? -120 : 120; showMobileControls(pane.element); setSlot(slot + amount); showSeekFeedback(amount); lastPaneTap = null; }
      else { const wasVisible = root.classList.contains('mobile-chrome'); lastPaneTap = { pane, at: now, x: event.clientX, y: event.clientY }; controlsRevealTimer = window.setTimeout(() => { lastPaneTap = null; if (wasVisible) hideMobileChrome(); else showMobileControls(pane.element); }, 320); }
    }
    layout.addEventListener('click', () => { showMobileChrome(); setInsetMode(!insetMode); });
    layout.hidden = cameras.length === 1;
    panes.forEach((pane) => pane.element.addEventListener('pointerup', (event) => { if (event.pointerType !== 'touch' && insetMode && !pane.element.classList.contains('inset-primary') && !event.target.closest('button, input')) setInsetPrimary(pane); }));
    mediaToggles.forEach((toggle) => { const pane = toggle.closest('.pane'); ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'dblclick'].forEach((type) => toggle.addEventListener(type, (event) => event.stopPropagation())); toggle.addEventListener('click', (event) => { event.stopPropagation(); showMobileControls(pane); setDesiredPlaying(!desiredPlaying); }); });
    settings.addEventListener('click', (event) => { event.stopPropagation(); const open = !timeline.classList.contains('speed-open'); closeSpeedMenu(); if (open) { timeline.classList.add('speed-open'); settings.setAttribute('aria-expanded', 'true'); } showMobileChrome(); });
    speedMenu.addEventListener('click', (event) => event.stopPropagation());
    mobileSpeed.addEventListener('change', () => { setSpeedIndex(mobileSpeed.value); closeSpeedMenu(); showMobileChrome(); });
    function toggleFullscreen() { if (document.fullscreenElement) document.exitFullscreen(); else if (root.requestFullscreen) root.requestFullscreen().catch(() => undefined); else if (panes[0].video.webkitEnterFullscreen) panes[0].video.webkitEnterFullscreen(); }
    fullscreen.hidden = !(document.fullscreenEnabled || root.requestFullscreen || panes[0].video.webkitEnterFullscreen);
    fullscreen.addEventListener('click', () => { showMobileChrome(); toggleFullscreen(); });
    window.addEventListener('hashchange', () => { const time = hashTime(); if (Number.isFinite(time)) pauseAtSlot(slotForTime(time)); });
    function stepFrames(amount) { pauseAtSlot(representedSlot() + amount); }
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

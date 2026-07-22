# Browser testing the map

How to visually exercise the built `index.html` + PMTiles in a real browser —
zoom, pan, click, and card rendering that the source-level `check-*-ui.py`
contracts and the fixture checks cannot see.

**Always test both form factors, every time:**

- **Desktop** — 1280×900. Side panel visible.
- **Mobile portrait** — 390×844. The panel collapses to a bottom sheet with
  active-filter chips; this is a distinct layout and must be checked separately.

Zoom, pan, and click/tap liberally in each: the low-zoom region/cluster overview,
the mid-zoom band handoffs, the z≥14 individual markers, and an open object card.

Prefer **headed Chromium and Firefox** on an Xvfb display for rendering fidelity;
the scriptable headless harness below is what CI-style automated checks use.

## WebGL prerequisites

The map needs a working WebGL2 context. The workstation profile already grants
the agent sandbox one: the GPU render node `/dev/dri/renderD128` is bound in and
made world-rw by a udev rule (`SUBSYSTEM=="drm", KERNEL=="renderD*",
MODE="0666"`), and `/run/opengl-driver` is bound. That covers headed browsers.
Headless additionally needs SwiftShader (below).

## Headless harness (scriptable)

- **Browser:** `chrome-headless-shell` from `pkgs.playwright-driver.browsers`.
  It bundles `libEGL`/`libGLESv2`/`libvk_swiftshader`; the nix `chromium` package
  does **not** (no ANGLE/EGL), so it cannot get a headless GL context.
- **Flags:** `--no-sandbox --enable-unsafe-swiftshader --use-angle=swiftshader
  --remote-debugging-port=9333 --remote-allow-origins=* --window-size=WxH`.
- **Display:** run it under `DISPLAY=:95` with `Xvfb :95 -screen 0 WxHx24`.
  SwiftShader's `DisplayVkXcb` needs a real X server; pure headless (no Xvfb)
  fails to initialise.
- **Drive it over the DevTools Protocol** (a websocket): `Page.enable`,
  `Runtime.enable`, `Page.navigate`, then a **real** `sleep(18–22 s)` so the
  vector tiles actually load, then optionally `Runtime.evaluate` an action, then
  `Page.captureScreenshot`.
  - Do **not** use `Emulation.setVirtualTimePolicy` / a virtual-time budget: it
    pauses the clock, so tiles never finish loading.
  - A PNG of ~350 KB+ means real map imagery rendered; ~40 KB means a gray canvas
    or the error page.
- **Serve the build with HTTP Range support.** PMTiles are read with range
  requests and require `206 Partial Content`; the stock python `http.server`
  does not implement Range, so use a tiny custom 206 handler. Serve an overlay
  directory: symlinks to every file in the build output, with `index.html` (and
  `metadata.json`, if injecting test data) replaced by real files.

## Driving zoom / pan / click

`map` is declared `let map` — module-scoped, **not** on `window`. To script
interactions, inject hooks **into the served overlay copy only** (never commit
them), right after the `map.on("click", …)` handler in `index.html`:

```js
window.__map = map;
window.__inspect = inspectPlaceMarker;
window.__placeLayerIds = placeLayerIds;
window.__serviceIconLayerId = serviceIconLayerId;
```

Then, inside a `Runtime.evaluate` action:

- **Zoom / pan:** `window.__map.jumpTo({ center: [lon, lat], zoom })`.
- **Open a card:** `queryRenderedFeatures({ layers: [__serviceIconLayerId,
  ...__placeLayerIds] })`, pick a feature, `window.__inspect(feature)`.
- **Click a control:** `[...document.querySelectorAll("button")]
  .find(b => /Visos paslaugos/.test(b.textContent)).click()`.

## Gotchas

- `pkill -f chrome-headless-shell` matches the killing command's **own** command
  line and SIGKILLs the shell running it (exit 1, no output). List with
  `ps -eo pid,comm | grep -i headless` and kill by PID instead. The driver
  already SIGKILLs its own `chrome`/`Xvfb` on exit, so a pre-kill is usually
  unnecessary.
- `map.once("idle", …)` **hangs** if the map already reached idle before the
  action runs (it fires ~20 s after navigate). For a no-jump view, query
  directly; a `jumpTo` triggers a fresh `idle`, so `once("idle")` is safe there.
- Start the server as a persistent background process; a `nohup … &` launched
  from inside a one-shot shell invocation may be reaped.

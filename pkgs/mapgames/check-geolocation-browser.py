#!/usr/bin/env python3
"""Deterministic MapLibre geolocation integration test in a running Chromium.

Serve a complete mapgames output containing the candidate index.html, launch
Chromium with remote debugging, then run, for example:

  ./check-geolocation-browser.py \
    --url http://127.0.0.1:9141/ --debug-port 9341

The script injects a deterministic Geolocation API before application code;
it never uses or exposes the machine's real position. It requires the
`websocket-client` Python package and Chromium's `--remote-allow-origins` flag
for the debug origin. It is intentionally a manual integration test rather
than a Nix check because the latter would add Chromium and a range-capable
HTTP server to every data test closure.
"""

import argparse
import json
import time
import urllib.request

import websocket


MOCK_GEOLOCATION = r"""
(() => {
  const state = {
    watchCalls: 0, clearCalls: [], nextId: 1,
    success: undefined, error: undefined, options: undefined
  };
  state.emit = (lat, lon, accuracy) => state.success({
    coords: {latitude: lat, longitude: lon, accuracy,
      altitude: null, altitudeAccuracy: null, heading: null, speed: null},
    timestamp: Date.now()
  });
  state.emitError = code => state.error({code, message: `mock-${code}`});
  const geolocation = {
    watchPosition(success, error, options) {
      state.watchCalls += 1;
      state.success = success;
      state.error = error;
      state.options = options;
      return state.nextId++;
    },
    clearWatch(id) { state.clearCalls.push(id); },
    getCurrentPosition() { throw new Error("unexpected getCurrentPosition"); }
  };
  Object.defineProperty(Navigator.prototype, "geolocation", {
    configurable: true, get: () => geolocation
  });
  if (globalThis.Permissions?.prototype?.query) {
    Permissions.prototype.query = function(descriptor) {
      if (descriptor?.name === "geolocation") return Promise.resolve({state: "granted"});
      return Promise.resolve({state: "prompt"});
    };
  }
  window.__geoTest = state;
})();
"""

UNSUPPORTED_GEOLOCATION = r"""
Object.defineProperty(Navigator.prototype, "geolocation", {
  configurable: true, get: () => undefined
});
"""


class Page:
    def __init__(self, debug_origin, url, injection):
        request = urllib.request.Request(f"{debug_origin}/json/new?about:blank", method="PUT")
        target = json.load(urllib.request.urlopen(request, timeout=5))
        self.ws = websocket.create_connection(
            target["webSocketDebuggerUrl"], origin=debug_origin, timeout=15
        )
        self.serial = 0
        self.requests = []
        self.call("Page.enable")
        self.call("Network.enable")
        self.call("Page.addScriptToEvaluateOnNewDocument", {"source": injection})
        self.call("Page.navigate", {"url": url})
        self.wait_for("document.readyState === 'complete' && !!document.querySelector('.maplibregl-ctrl-geolocate')")

    def call(self, method, params=None):
        self.serial += 1
        serial = self.serial
        self.ws.send(json.dumps({"id": serial, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("method") == "Network.requestWillBeSent":
                self.requests.append(message["params"]["request"]["url"])
            if message.get("id") != serial:
                continue
            if "error" in message:
                raise AssertionError(message["error"])
            return message.get("result", {})

    def eval(self, expression):
        result = self.call("Runtime.evaluate", {
            "expression": expression, "returnByValue": True, "awaitPromise": True
        })
        if result.get("exceptionDetails"):
            raise AssertionError(result["exceptionDetails"])
        return result.get("result", {}).get("value")

    def wait_for(self, expression, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.eval(expression):
                return
            time.sleep(0.05)
        raise AssertionError(f"timed out: {expression}")

    def close(self):
        self.ws.close()


def assert_no_location_leak(page, original_hash):
    assert page.eval("location.hash") == original_hash, "device camera leaked into URL hash"
    coordinate_fragments = ("54.6872", "25.2797", "54.688", "25.281")
    assert not [url for url in page.requests if any(value in url for value in coordinate_fragments)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--debug-port", type=int, required=True)
    args = parser.parse_args()
    debug_origin = f"http://127.0.0.1:{args.debug_port}"

    page = Page(debug_origin, args.url, MOCK_GEOLOCATION)
    try:
        assert page.eval("__geoTest.watchCalls") == 0, "page requested location before user action"
        original_hash = page.eval("location.hash")
        page.eval("document.querySelector('.maplibregl-ctrl-geolocate').click()")
        assert page.eval("__geoTest.watchCalls") == 1
        assert page.eval("__geoTest.options.enableHighAccuracy") is True
        page.eval("__geoTest.emit(54.6872, 25.2797, 25)")
        page.wait_for("!!document.querySelector('.maplibregl-user-location-dot')?.parentElement?.isConnected")
        assert page.eval("!document.querySelector('.maplibregl-user-location-accuracy-circle').hidden")
        assert "±25 m" in page.eval("document.querySelector('#geolocation-status').textContent")
        assert page.eval("!document.querySelector('#location-dialog').open")

        # A real pointer click on the location marker is not a map inspection.
        point = page.eval("""(() => { const r = document.querySelector(
          '.maplibregl-user-location-dot').getBoundingClientRect();
          return {x: r.x + r.width / 2, y: r.y + r.height / 2}; })()""")
        for kind in ("mousePressed", "mouseReleased"):
            page.call("Input.dispatchMouseEvent", {
                "type": kind, "x": point["x"], "y": point["y"],
                "button": "left", "clickCount": 1
            })
        assert page.eval("!document.querySelector('#location-dialog').open")

        for accuracy in ("-1", "NaN", "Infinity", "Number.MAX_VALUE", "10001"):
            page.eval("__geoTest.emit(54.6872, 25.2797, 25)")
            page.eval(f"__geoTest.emit(54.6872, 25.2797, {accuracy})")
            assert page.eval("document.querySelector('.maplibregl-user-location-accuracy-circle').hidden")
            assert "±" not in page.eval("document.querySelector('#geolocation-status').textContent")

        # Pan enters background mode; updates move the dot without refetching
        # or opening a modal. First press recentres, second stops and clears.
        page.eval("map.panBy([80, 0], {duration: 0}); true")
        page.wait_for("geolocationCameraFollowing === false")
        page.eval("__geoTest.emit(54.688, 25.281, 12)")
        assert "Vieta toliau" in page.eval("document.querySelector('#geolocation-status').textContent")
        page.eval("document.querySelector('.maplibregl-ctrl-geolocate').click()")
        assert page.eval("__geoTest.watchCalls") == 1, "recenter created a second watch"
        page.eval("document.querySelector('.maplibregl-ctrl-geolocate').click()")
        assert page.eval("__geoTest.clearCalls.length") == 1
        assert page.eval("document.querySelector('.maplibregl-ctrl-geolocate').getAttribute('aria-pressed')") == "false"

        # Removing an active control must clear its watch and marker.
        page.eval("document.querySelector('.maplibregl-ctrl-geolocate').click()")
        assert page.eval("__geoTest.watchCalls") == 2
        page.eval("map.removeControl(geolocationControl); true")
        assert page.eval("__geoTest.clearCalls.length") == 2
        assert_no_location_leak(page, original_hash)
    finally:
        page.close()

    for code, expected in ((1, "leidimas"), (2, "nepavyko nustatyti"), (3, "laiku nepavyko")):
        page = Page(debug_origin, args.url, MOCK_GEOLOCATION)
        try:
            original_hash = page.eval("location.hash")
            page.eval("document.querySelector('.maplibregl-ctrl-geolocate').click()")
            page.eval(f"__geoTest.emitError({code})")
            assert expected in page.eval("document.querySelector('#geolocation-status').textContent")
            assert not page.eval("document.querySelector('#location-dialog').open")
            assert_no_location_leak(page, original_hash)
        finally:
            page.close()

    page = Page(debug_origin, args.url, UNSUPPORTED_GEOLOCATION)
    try:
        assert page.eval("document.querySelector('.maplibregl-ctrl-geolocate').disabled")
        assert "negalima" in page.eval("document.querySelector('#geolocation-status').textContent")
    finally:
        page.close()

    print("geolocation Chromium integration passed")


if __name__ == "__main__":
    main()

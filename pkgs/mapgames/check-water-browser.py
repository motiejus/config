#!/usr/bin/env python3
"""Manual Chromium contract test for the potable-water presentation.

Serve a complete candidate mapgames output and launch Chromium with remote
debugging, then run, for example:

  ./check-water-browser.py --url http://127.0.0.1:9141/ --debug-port 9341

Like the geolocation browser test, this stays manual so the normal Nix check
closure does not acquire Chromium, Caddy, or websocket-client.
"""

import argparse
import json
import time
import urllib.request

import websocket


class Page:
    def __init__(self, debug_origin: str, url: str):
        request = urllib.request.Request(f"{debug_origin}/json/new?about:blank", method="PUT")
        target = json.load(urllib.request.urlopen(request, timeout=5))
        self.ws = websocket.create_connection(
            target["webSocketDebuggerUrl"], origin=debug_origin, timeout=15
        )
        self.serial = 0
        self.call("Page.enable")
        self.call("Page.navigate", {"url": url})
        # A top-level `const map` lives in the page's global lexical scope,
        # not as a mutable `globalThis.map` property. DevTools evaluation can
        # read that binding directly; do not make production map state public
        # merely to support this manual contract test.
        self.wait_for(
            "typeof map !== 'undefined' && map.isStyleLoaded() && "
            "!!map.getLayer('detail-water-badge')"
        )

    def call(self, method: str, params=None):
        self.serial += 1
        serial = self.serial
        self.ws.send(json.dumps({"id": serial, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") != serial:
                continue
            if "error" in message:
                raise AssertionError(message["error"])
            return message.get("result", {})

    def eval(self, expression: str):
        result = self.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        if result.get("exceptionDetails"):
            raise AssertionError(result["exceptionDetails"])
        return result.get("result", {}).get("value")

    def wait_for(self, expression: str, timeout: float = 8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.eval(expression):
                return
            time.sleep(0.05)
        raise AssertionError(f"timed out: {expression}")

    def close(self):
        self.ws.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--debug-port", type=int, required=True)
    args = parser.parse_args()
    origin = f"http://127.0.0.1:{args.debug_port}"
    page = Page(origin, args.url)
    try:
        policy = page.eval(
            """(() => {
              const layers = map.getStyle().layers;
              const dot = map.getLayer('detail-water-dot');
              const badge = map.getLayer('detail-water-badge');
              const name = map.getLayer('detail-water-names');
              const generic = map.getLayer('detail-micro-markers');
              return {
                dotMin: dot.minzoom, badgeMin: badge.minzoom, nameMin: name.minzoom,
                dotFilter: JSON.stringify(dot.filter),
                badgeFilter: JSON.stringify(badge.filter),
                genericFilter: JSON.stringify(generic.filter),
                overlap: map.getLayoutProperty(badge.id, 'text-allow-overlap'),
                ignores: map.getLayoutProperty(badge.id, 'text-ignore-placement'),
                badgeText: map.getLayoutProperty(badge.id, 'text-field'),
                nameText: JSON.stringify(map.getLayoutProperty(name.id, 'text-field')),
                nameIndex: layers.findIndex(layer => layer.id === name.id),
                dotIndex: layers.findIndex(layer => layer.id === dot.id),
                badgeIndex: layers.findIndex(layer => layer.id === badge.id),
                firstBaseSymbol: layers.findIndex(layer =>
                  layer.type === 'symbol' && !layer.id.startsWith('detail-'))
              };
            })()"""
        )
        assert policy["dotMin"] == 15 and policy["badgeMin"] == 16
        assert policy["nameMin"] == 18
        assert policy["overlap"] is True and policy["ignores"] is True
        assert policy["badgeText"] == "H₂O"
        assert '"name"' in policy["nameText"]
        assert '"drinking_water"' in policy["dotFilter"]
        assert policy["dotFilter"] == policy["badgeFilter"]
        assert '"!="' in policy["genericFilter"] and '"drinking_water"' in policy["genericFilter"]
        assert policy["nameIndex"] < policy["firstBaseSymbol"] < policy["dotIndex"] < policy["badgeIndex"], (
            "potable-water marker must be above collision-prone basemap labels"
        )

        # The language switch rewrites localized detail text. The neutral dot
        # and H₂O badge must stay out of that rewrite, while the optional name
        # follows the selected language without producing a style-validation
        # error for the circle layer.
        initial_language = page.eval("document.documentElement.lang")
        next_language = "en" if initial_language == "lt" else "lt"
        page.eval(
            """(() => {
              globalThis.__waterContractErrors = [];
              map.on('error', event =>
                globalThis.__waterContractErrors.push(String(event.error?.message || event.error)));
              document.getElementById('lang-toggle').click();
              return true;
            })()"""
        )
        page.wait_for(f"document.documentElement.lang === '{next_language}'")
        assert page.eval("map.getLayoutProperty('detail-water-badge', 'text-field')") == "H₂O"
        assert not page.eval(
            "__waterContractErrors.some(message => "
            "/detail-water|text-field|unknown property/i.test(message))"
        ), page.eval("__waterContractErrors")

        # Zooming must not remove/recreate either layer; the compact dot is
        # eligible at z15 and the explanatory badge joins it at z16.
        for zoom in (15, 16, 18):
            page.eval(f"map.jumpTo({{zoom: {zoom}}}); true")
            page.wait_for("!map.isMoving()")
            assert page.eval("!!map.getLayer('detail-water-dot')")
            assert page.eval("!!map.getLayer('detail-water-badge')")
    finally:
        page.close()

    print("potable-water Chromium contract passed")


if __name__ == "__main__":
    main()

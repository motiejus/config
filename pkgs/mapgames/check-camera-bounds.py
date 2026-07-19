#!/usr/bin/env python3

"""Contract and projection checks for viewport-aware map constraints."""

import argparse
import math
from pathlib import Path


TILE_SIZE = 512
GUTTER = 32
BBOX = (20.618591, 53.892206, 26.83873, 56.45329)


def mercator_y(latitude: float) -> float:
    latitude = max(-85.051129, min(85.051129, latitude))
    radians = math.radians(latitude)
    return (1 - math.asinh(math.tan(radians)) / math.pi) / 2


def latitude_from_y(y: float) -> float:
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y))))


def center_bounds(zoom: int, east_extra=0, south_extra=0):
    min_lon, min_lat, max_lon, max_lat = BBOX
    world = TILE_SIZE * 2**zoom
    west = min_lon - GUTTER / world * 360
    east = max_lon + (GUTTER + east_extra) / world * 360
    north = latitude_from_y(mercator_y(max_lat) - GUTTER / world)
    south = latitude_from_y(
        mercator_y(min_lat) + (GUTTER + south_extra) / world
    )
    return west, south, east, north


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    args = parser.parse_args()
    source = args.index.read_text(encoding="utf-8")

    required = [
        "function mercatorY(latitude)",
        "function latitudeFromMercatorY(y)",
        "function measurePanelOverscroll(width, height)",
        "function constrainCameraCenter(lngLat, zoom)",
        "const cameraEdgeGutter = 32;",
        "const cameraTileSize = 512;",
        "const constrainedZoom = Math.max(cameraMinZoom, Math.min(cameraMaxZoom, zoom));",
        "transformConstrain: constrainCameraCenter,",
        "cameraCoverageBounds = metadata.bbox;",
        "if (measureKey === cameraPanelMeasureKey) return;",
    ]
    for fragment in required:
        assert fragment in source, f"missing camera-bounds contract: {fragment}"
    assert "scheduleCameraBoundsRefresh" not in source
    assert 'map.on("resize"' not in source
    # Panel allowances only grow, so collapsing a panel cannot suddenly clamp
    # and shift a camera that was positioned while it was open.
    for side in ("west", "east", "north", "south"):
        assert f"cameraPanelOverscroll.{side} = Math.max(" in source

    # Every edge is inside the allowed center range by the interaction gutter.
    # Unlike a static min-zoom maxBounds expansion, the excess shrinks with
    # zoom and does not expose a country-sized void at street level.
    previous_excess = None
    for zoom in (6, 12, 18):
        west, south, east, north = center_bounds(zoom)
        assert west < BBOX[0] < BBOX[2] < east
        assert south < BBOX[1] < BBOX[3] < north
        excess = east - BBOX[2]
        if previous_excess is not None:
            assert excess < previous_excess / 50
        previous_excess = excess
    assert center_bounds(18)[2] - BBOX[2] < 0.0001

    # An open desktop side panel needs eastward camera travel; a mobile bottom
    # sheet needs southward travel. Both expansions must be directional and
    # additive without changing the opposite edge.
    base = center_bounds(12)
    desktop = center_bounds(12, east_extra=220)
    assert desktop[0] == base[0] and desktop[1] == base[1]
    assert desktop[2] > base[2] and desktop[3] == base[3]
    mobile_base = center_bounds(12)
    mobile = center_bounds(12, south_extra=180)
    assert mobile[0] == mobile_base[0] and mobile[2:] == mobile_base[2:]
    assert mobile[1] < mobile_base[1]

    print("camera bounds contract passed")


if __name__ == "__main__":
    main()

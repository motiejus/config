#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser()
    package = Path(__file__).resolve().parent
    parser.add_argument("--fixture", type=Path, default=package / "testdata/transit.osm")
    parser.add_argument("--index", type=Path, default=package / "index.html")
    parser.add_argument("--osmium", default="osmium")
    parser.add_argument("--transit", type=Path, default=package / "transit.py")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mapgames-transit-fixture-") as temporary:
        temporary = Path(temporary)
        pbf = temporary / "transit.osm.pbf"
        output = temporary / "transit.geojson"
        subprocess.run([args.osmium, "cat", args.fixture, "-o", pbf], check=True)
        subprocess.run([
            sys.executable, args.transit, "--input", pbf, "--output", output,
            "--work", temporary, "--bbox", "24.99,54.99,25.03,55.03",
            "--osmium", args.osmium,
        ], check=True)
        features = json.loads(output.read_text(encoding="utf-8"))["features"]

    by_name = {}
    unnamed = []
    for feature in features:
        properties = feature["properties"]
        name = properties.get("name") or properties.get("name:lt") or properties.get("name:en")
        if name:
            by_name.setdefault(name, []).append(properties)
        else:
            unnamed.append(properties)
    assert len(by_name["Opposite"]) == 1 and by_name["Opposite"][0]["platform_count"] == 2
    assert by_name["Opposite"][0]["ref"] == "A/B"
    assert len(by_name["Orphan"]) == 1
    assert len(by_name["Area canonical"]) == 1 and "Member name" not in by_name
    area = by_name["Area canonical"][0]
    assert area["kind"] == "terminal" and area["display_tier"] == 15
    assert area["mode_bus"] == 1 and area["mode_trolleybus"] == 1 and area["mode_tram"] == 1
    assert area["ref"] == "R42"
    assert len(by_name["Central"]) == 1 and by_name["Central"][0]["platform_count"] == 1
    assert by_name["Multimodal"][0]["display_tier"] == 16
    assert by_name["Multimodal"][0]["mode_bus"] == 1 and by_name["Multimodal"][0]["mode_tram"] == 1
    assert "Disused" not in by_name
    assert "Razed" not in by_name and "Demolished" not in by_name
    assert len(by_name["Active despite false lifecycle"]) == 1
    assert len(unnamed) == 1 and unnamed[0]["display_tier"] == 18
    trolley = by_name["Trolley only"][0]
    assert trolley["mode_trolleybus"] == 1 and "mode_bus" not in trolley and trolley["primary_mode"] == "trolleybus"
    terminal = by_name["Bus Terminal"][0]
    assert terminal["kind"] == "terminal" and terminal["display_tier"] == 15 and terminal["ref"] == "T1"
    index = args.index.read_text(encoding="utf-8")
    assert '"text-anchor": "top",\n            "text-offset": [0, 0.9]' in index, (
        "transit text must be offset below its marker so ring/dot shape remains visible"
    )
    assert 'const transitMarkerLayer = (id, tier, minzoom = tier)' in index
    assert 'transitMarkerLayer("detail-transit-markers-17", 17, 16)' in index, (
        "named local-stop markers must appear at z16 while retaining their z17 label tier"
    )
    assert 'transitLayer("detail-transit-local", 17,' in index, (
        "local-stop labels must remain z17-only to avoid z16 text clutter"
    )
    assert '"circle-color": "#fffaf1"' in index, (
        "all transit markers need a light centre that contrasts with dark road casings"
    )
    assert '["station", "terminal"], 5, "halt", 4, 3.5]' in index
    assert '["station", "terminal"], 2, 1.5]' in index
    print(f"transit fixture passed ({len(features)} canonical stops)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
import re
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
    assert area["platform_count"] == 1 and "mode_ferry" not in area
    assert area["ref"] == "R42"
    assert "Disabled relation member" not in by_name
    assert "Disabled stop area" not in by_name and "Must not resurrect" not in by_name
    assert len(by_name["Malformed survivor"]) == 1
    assert len(by_name["Central"]) == 1 and by_name["Central"][0]["platform_count"] == 1
    assert by_name["Multimodal"][0]["display_tier"] == 16
    assert by_name["Multimodal"][0]["mode_bus"] == 1 and by_name["Multimodal"][0]["mode_tram"] == 1
    assert by_name["Multimodal"][0]["mode_count"] == 2
    assert "Disused" not in by_name
    assert "Razed" not in by_name and "Demolished" not in by_name
    assert len(by_name["Active despite false lifecycle"]) == 1
    assert len(unnamed) == 1 and unnamed[0]["display_tier"] == 18
    trolley = by_name["Trolley only"][0]
    assert trolley["mode_trolleybus"] == 1 and "mode_bus" not in trolley and trolley["primary_mode"] == "trolleybus"
    assert trolley["mode_count"] == 1
    subway = by_name["Subway only"][0]
    assert subway["mode_subway"] == 1 and "mode_train" not in subway and subway["mode_count"] == 1
    tagged_trolley = by_name["Tagged trolley only"][0]
    assert tagged_trolley["mode_trolleybus"] == 1 and "mode_bus" not in tagged_trolley
    assert by_name["Explicit bus no"][0]["mode_count"] == 0
    assert "mode_bus" not in by_name["Explicit bus no"][0]
    explicit_multi = by_name["Explicit bus and trolley"][0]
    assert explicit_multi["mode_bus"] == 1 and explicit_multi["mode_trolleybus"] == 1
    assert explicit_multi["mode_count"] == 2
    relation_subway = by_name["Relation subway only"][0]
    assert relation_subway["mode_subway"] == 1 and "mode_train" not in relation_subway
    assert relation_subway["mode_count"] == 1 and relation_subway["primary_mode"] == "subway"
    relation_no_train = by_name["Relation explicit train no"][0]
    assert relation_no_train["mode_count"] == 0 and "mode_train" not in relation_no_train
    assert "Generic subway member" not in by_name and "Generic no-train member" not in by_name
    generic_anchor = by_name["Generic anchor first"][0]
    explicit_anchor = by_name["Explicit anchor first"][0]
    for clustered in (generic_anchor, explicit_anchor):
        assert clustered["mode_count"] == 2
        assert clustered["mode_train"] == 1 and clustered["mode_subway"] == 1
    relation_no_wins = by_name["Relation no wins"][0]
    assert relation_no_wins["mode_count"] == 1
    assert relation_no_wins["mode_subway"] == 1 and "mode_train" not in relation_no_wins
    assert "Contradictory member" not in by_name
    terminal = by_name["Bus Terminal"][0]
    assert terminal["kind"] == "terminal" and terminal["display_tier"] == 15 and terminal["ref"] == "T1"
    index = args.index.read_text(encoding="utf-8")
    assert '"text-anchor": "top",\n            "text-offset": [0, 0.9]' in index, (
        "transit text must be offset below its marker so ring/dot shape remains visible"
    )
    policy_match = re.search(
        r"const transitZoomPolicy = (\{.*?\n        \});", index, re.DOTALL
    )
    assert policy_match, "transit zoom policy must remain explicit and machine-readable"
    policy = json.loads(policy_match.group(1))
    assert policy == {
        "15": {"marker": 15, "label": 15},
        "16": {"marker": 15, "label": 16},
        "17": {"marker": 15, "label": 17},
        "18": {"marker": 18, "label": 18},
    }, "all named markers start at z15; labels stay tiered; unnamed markers stay z18"
    assert "minzoom: transitZoomPolicy[tier].marker" in index
    assert "minzoom: transitZoomPolicy[tier].label" in index
    marker_tiers = {
        int(tier) for tier in re.findall(r'transitMarkerLayer\("[^"]+", (\d+)\)', index)
    }
    label_tiers = {
        int(tier) for tier in re.findall(r'transitLayer\("[^"]+", (\d+),', index)
    }
    assert marker_tiers == {15, 16, 17, 18}
    assert label_tiers == {15, 16, 17}
    assert '"icon-image": transitIconField()' in index
    assert '"mapgames-transit-interchange"' in index
    assert '"train", "train_station"' in index
    assert '"subway", "mapgames-subway"' in index
    assert '"tram", "mapgames-tram"' in index
    assert '"trolleybus", "mapgames-trolleybus"' in index
    assert '"bus", "mapgames-bus"' in index
    assert '"ferry", "ferry_terminal"' in index
    assert '"mapgames-transit-stop"' in index
    icon_size = index[index.index("function transitIconSize"):
                      index.index("function updateDetailLanguage")]
    assert "24 / 19" in icon_size, (
        "19px pinned train/ferry sprites are optically smaller than 24px custom artwork"
    )
    assert '["train", "ferry"], 24 / 19, 1' in icon_size
    assert '"mode_count"' in icon_size, (
        "the custom multi-mode icon must not receive pinned-atlas compensation"
    )
    assert "15, atZoom(0.9, 0.78, 0.72)" in icon_size
    assert "17, atZoom(1.05, 0.94, 0.88)" in icon_size
    assert 'return ["interpolate", ["linear"], ["zoom"],' in icon_size, (
        "MapLibre requires zoom below a top-level step/interpolate expression"
    )
    assert 'return ["*", hierarchy' not in icon_size
    assert '"icon-size": transitIconSize()' in index
    assert '"icon-allow-overlap": true' in index and '"icon-ignore-placement": true' in index
    assert '"symbol-sort-key": ["-", 0, ["get", "rank"]]' in index
    assert "transitBadgeLayer" not in index and "transitBadgeField" not in index, (
        "cryptic letter badges must not obscure the transport pictograms"
    )
    assert 'addImportantTransitLabel(transitLayer("detail-transit-station"' in index
    assert 'addImportantTransitLabel(transitLayer("detail-transit-halt"' in index
    assert '["roads_shields", "roads_labels_major"]' in index
    assert 'return detailLocalizedField("name");' in index, (
        "mode pictograms must not be repeated as wide text that suppresses stop names"
    )
    print(f"transit fixture passed ({len(features)} canonical stops)")


if __name__ == "__main__":
    main()

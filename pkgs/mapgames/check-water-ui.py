#!/usr/bin/env python3
"""Static, hermetic contract for language-safe potable-water layers."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    args = parser.parse_args()
    index = args.index.read_text(encoding="utf-8")

    ids_start = index.index("const detailLayerIds = [")
    ids = index[ids_start:index.index("];", ids_start)]
    assert '"detail-water-names"' in ids, "localized potable-water names are not refreshed"
    assert '"detail-water-dot"' not in ids and '"detail-water-badge"' not in ids, (
        "language refresh must not assign text-field to the dot or replace the H₂O badge"
    )

    update = index[
        index.index("function updateDetailLanguage()"):
        index.index("function addDetailLayers()")
    ]
    assert 'id === "detail-water-names" ? detailLocalizedField("name")' in update, (
        "potable-water proper names do not follow the selected language"
    )

    water = index[
        index.index('id: "detail-water-names"'):
        index.index("function discardInspectorLayers")
    ]
    assert '"source-layer": details.layers.water_details' in water
    assert 'id: "detail-water-badge"' in water and '"text-field": "H₂O"' in water
    assert '"text-allow-overlap": true' in water and '"text-ignore-placement": true' in water

    print("potable-water UI contract passed")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import re
import subprocess
import unicodedata
from urllib.parse import unquote


LIFECYCLE = {"abandoned", "construction", "demolished", "disused", "proposed", "razed", "removed"}
KIND_PRIORITY = {"stop": 0, "halt": 1, "station": 2, "terminal": 3}
MODE_PRIORITY = ("train", "subway", "tram", "trolleybus", "bus", "ferry")


def run(argv: list[object], capture: bool = False) -> str:
    result = subprocess.run(
        [str(value) for value in argv],
        check=True,
        text=capture,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout if capture else ""


def point_for_geometry(geometry: dict) -> tuple[float, float] | None:
    coordinates = geometry.get("coordinates")
    if geometry.get("type") == "Point" and coordinates:
        return float(coordinates[0]), float(coordinates[1])

    points = []

    def collect(value):
        if not isinstance(value, list):
            return
        if len(value) >= 2 and all(isinstance(item, (int, float)) for item in value[:2]):
            points.append((float(value[0]), float(value[1])))
        else:
            for item in value:
                collect(item)

    collect(coordinates)
    if not points:
        return None
    return sum(point[0] for point in points) / len(points), sum(point[1] for point in points) / len(points)


def osm_key(feature_id: object) -> str:
    value = str(feature_id or "")
    if value.startswith("a") and value[1:].isdigit():
        area_id = int(value[1:])
        return ("w" if area_id % 2 == 0 else "r") + str(
            area_id // 2 if area_id % 2 == 0 else (area_id - 1) // 2
        )
    return value


def excluded(properties: dict) -> bool:
    false_values = {"", "no", "false", "0"}
    for key, value in properties.items():
        key_text = str(key).lower()
        value_text = str(value).lower()
        if value_text in LIFECYCLE and key_text in ("public_transport", "railway", "highway", "amenity"):
            return True
        if (key_text in LIFECYCLE or key_text.split(":", 1)[0] in LIFECYCLE) and value_text not in false_values:
            return True
    return False


def names(properties: dict) -> dict:
    return {
        key: str(properties[key])
        for key in ("name", "name:lt", "name:en")
        if properties.get(key)
    }


def preferred_name(properties: dict) -> str:
    for key in ("name", "name:lt", "name:en"):
        if properties.get(key):
            return str(properties[key])
    return ""


def normalized_name(properties: dict) -> str:
    value = unicodedata.normalize("NFKD", preferred_name(properties)).casefold()
    value = "".join(character for character in value if not unicodedata.combining(character))
    return " ".join(re.sub(r"[^\w]+", " ", value).split())


def explicit_modes(properties: dict) -> tuple[set[str], set[str]]:
    values = {
        mode: str(properties.get(mode) or "").strip().lower()
        for mode in MODE_PRIORITY
    }
    return (
        {mode for mode, value in values.items() if value == "yes"},
        {mode for mode, value in values.items() if value == "no"},
    )


def inferred_modes(properties: dict, explicit_no: set[str] | None = None) -> set[str]:
    explicit_no = explicit_no or set()
    inferred = set()
    if "bus" not in explicit_no and (
        properties.get("highway") == "bus_stop" or properties.get("amenity") == "bus_station"
    ):
        inferred.add("bus")
    if "tram" not in explicit_no and properties.get("railway") == "tram_stop":
        inferred.add("tram")
    if "train" not in explicit_no and properties.get("railway") in ("station", "halt"):
        inferred.add("train")
    if "ferry" not in explicit_no and properties.get("amenity") == "ferry_terminal":
        inferred.add("ferry")
    return inferred


def modes(properties: dict) -> set[str]:
    explicit_yes, explicit_no = explicit_modes(properties)
    if explicit_yes:
        # A generic railway=station or highway=bus_stop describes the feature,
        # not an additional service mode. Once an explicit mode is present,
        # require every genuinely additional mode to be explicit too. Thus a
        # subway station is not mislabeled train+subway and a trolleybus stop
        # is not mislabeled bus+trolleybus.
        return explicit_yes
    return inferred_modes(properties, explicit_no)


def candidate_kind(properties: dict) -> str | None:
    if excluded(properties):
        return None
    if properties.get("amenity") in ("bus_station", "ferry_terminal"):
        return "terminal"
    if properties.get("railway") == "station" or properties.get("public_transport") == "station":
        return "station"
    if properties.get("railway") == "halt":
        return "halt"
    if properties.get("public_transport") == "stop_position":
        return "stop_position"
    if properties.get("public_transport") == "platform" or properties.get("highway") == "bus_stop" or properties.get("railway") == "tram_stop":
        return "platform"
    return None


def short_refs(items: list[dict]) -> str:
    values = []
    for item in items:
        for key in ("ref", "local_ref"):
            value = str(item["properties"].get(key) or "").strip()
            if value and len(value) <= 12 and value not in values:
                values.append(value)
    joined = "/".join(values[:3])
    return joined if len(joined) <= 24 else ""


def distance_meters(left: dict, right: dict) -> float:
    lon1, lat1 = left["coordinates"]
    lon2, lat2 = right["coordinates"]
    mean_lat = math.radians((lat1 + lat2) / 2)
    dx = math.radians(lon2 - lon1) * math.cos(mean_lat)
    dy = math.radians(lat2 - lat1)
    return 6371008.8 * math.hypot(dx, dy)


def merge_names(primary: dict, members: list[dict]) -> dict:
    result = names(primary)
    for member in members:
        for key, value in names(member["properties"]).items():
            result.setdefault(key, value)
    return result


def canonical_feature(identity: str, primary: dict, members: list[dict], kind: str | None = None) -> dict:
    coordinates = primary.get("coordinates")
    relation_primary = coordinates is None
    if coordinates is None:
        coordinates = (
            sum(member["coordinates"][0] for member in members) / len(members),
            sum(member["coordinates"][1] for member in members) / len(members),
        )
    primary_properties = primary.get("properties", {})
    if relation_primary:
        primary_yes, primary_no = explicit_modes(primary_properties)
        member_explicit = set()
        member_fallback = set()
        for member in members:
            member_yes, member_no = explicit_modes(member["properties"])
            member_explicit.update(member_yes)
            if not member_yes:
                member_fallback.update(inferred_modes(member["properties"], member_no))
        if primary_yes:
            # Stop-area mode tags describe the canonical facility. Preserve a
            # genuinely additional mode explicitly declared by a member, but
            # do not let generic railway/highway classification invent one.
            member_modes = primary_yes | member_explicit
        else:
            member_modes = modes(primary_properties) | member_explicit | member_fallback
        # A relation is the facility-level declaration, so its explicit `no`
        # vetoes both generic inference and a contradictory member `yes`.
        member_modes -= primary_no
    else:
        # Name/distance clusters do not have facility-level relation tags.
        # Normalize every object locally, then union the results; choosing an
        # equal-kind display anchor must never change the canonical modes.
        member_modes = modes(primary_properties) | set().union(*(
            modes(member["properties"]) for member in members
        ))
    member_kinds = [member["kind"] for member in members if member["kind"] not in ("platform", "stop_position")]
    primary_kind = candidate_kind(primary.get("properties", {}))
    if primary_kind in KIND_PRIORITY:
        member_kinds.append(primary_kind)
    resolved_kind = kind or (max(member_kinds, key=lambda value: KIND_PRIORITY[value]) if member_kinds else "stop")
    properties = merge_names(primary.get("properties", {}), members)
    properties["kind"] = resolved_kind
    properties["platform_count"] = sum(member["kind"] == "platform" for member in members)
    properties["primary_mode"] = next((mode for mode in MODE_PRIORITY if mode in member_modes), "")
    # Keep the renderer from having to infer interchanges from every possible
    # combination of mode_* flags. The individual flags remain authoritative
    # (and available to the inspector); this compact count is presentation
    # metadata for the visible badge and label only.
    properties["mode_count"] = len(member_modes)
    for mode in MODE_PRIORITY:
        if mode in member_modes:
            properties[f"mode_{mode}"] = 1
    reference = short_refs([{"properties": primary.get("properties", {})}, *members])
    if reference:
        properties["ref"] = reference
    named = bool(preferred_name(properties))
    if not named:
        display_tier, rank = 18, 90
    elif resolved_kind in ("station", "terminal"):
        display_tier, rank = 15, 12
    elif resolved_kind == "halt" or len(member_modes) > 1 or properties["platform_count"] >= 4:
        display_tier, rank = 16, 28
    else:
        display_tier, rank = 17, 48
    properties["display_tier"] = display_tier
    properties["rank"] = rank
    properties = {key: value for key, value in properties.items() if value not in ("", None)}
    return {
        "type": "Feature",
        "id": identity,
        "geometry": {"type": "Point", "coordinates": list(coordinates)},
        "properties": properties,
    }


def parse_opl_relations(text: str) -> list[dict]:
    def decode(value: str) -> str:
        # OPL delimits percent-escaped bytes on both sides (`%20%`). Decode
        # that form first; urllib alone would misread the following letters
        # as another hexadecimal escape (for example `%20%canonical`).
        value = re.sub(
            r"%([0-9A-Fa-f]{2})%",
            lambda match: chr(int(match.group(1), 16)),
            value,
        )
        return unquote(value)

    result = []
    for line in text.splitlines():
        if not line.startswith("r"):
            continue
        fields = {part[0]: part[1:] for part in line.split()[1:] if part}
        properties = {}
        for item in fields.get("T", "").split(","):
            if "=" in item:
                key, value = item.split("=", 1)
                properties[decode(key)] = decode(value)
        if properties.get("public_transport") != "stop_area" or properties.get("type") not in (
            None,
            "",
            "public_transport",
        ):
            continue
        members = []
        for item in fields.get("M", "").split(","):
            match = re.fullmatch(r"([nwr]\d+)@.*", item)
            if match:
                members.append(match.group(1))
        result.append({"id": line.split()[0], "properties": properties, "members": members})
    return result


def connected_clusters(items: list[dict], distance: float) -> list[list[dict]]:
    remaining = set(range(len(items)))
    result = []
    while remaining:
        pending = [remaining.pop()]
        indexes = []
        while pending:
            index = pending.pop()
            indexes.append(index)
            neighbours = [other for other in remaining if distance_meters(items[index], items[other]) <= distance]
            for other in neighbours:
                remaining.remove(other)
                pending.append(other)
        result.append([items[index] for index in indexes])
    return result


def prepare(pbf: Path, output: Path, work: Path, bbox: tuple[float, float, float, float], osmium: str = "osmium") -> dict:
    filtered = work / "transit-candidates.osm.pbf"
    raw = work / "transit.raw.geojson"
    relations_pbf = work / "transit-stop-areas.osm.pbf"
    selectors = (
        "nwr/public_transport", "nwr/highway=bus_stop", "nwr/railway=station",
        "nwr/railway=halt", "nwr/railway=tram_stop", "nwr/amenity=bus_station",
        "nwr/amenity=ferry_terminal",
    )
    run([osmium, "tags-filter", "--overwrite", "-o", filtered, pbf, *selectors])
    run([osmium, "export", "--geometry-types=point,linestring,polygon", "--add-unique-id=type_id", "--overwrite", "-o", raw, filtered])
    run([osmium, "tags-filter", "-R", "--overwrite", "-o", relations_pbf, pbf, "r/public_transport=stop_area"])
    relation_text = run([osmium, "cat", relations_pbf, "-f", "opl"], capture=True)

    source = json.loads(raw.read_text(encoding="utf-8"))
    candidates = []
    min_lon, min_lat, max_lon, max_lat = bbox
    for feature in source.get("features", []):
        properties = dict(feature.get("properties") or {})
        kind = candidate_kind(properties)
        coordinates = point_for_geometry(feature.get("geometry") or {})
        if kind is None or coordinates is None:
            continue
        if not (min_lon <= coordinates[0] <= max_lon and min_lat <= coordinates[1] <= max_lat):
            continue
        candidates.append({
            "id": osm_key(feature.get("id")), "coordinates": coordinates, "properties": properties,
            "kind": kind, "normalized_name": normalized_name(properties),
        })
    by_id = {candidate["id"]: candidate for candidate in candidates}
    consumed = set()
    features = []

    for relation in parse_opl_relations(relation_text):
        members = [by_id[member] for member in relation["members"] if member in by_id and member not in consumed]
        if excluded(relation["properties"]):
            # A lifecycle-disabled stop area disables its members as a unit.
            # Consume otherwise-active candidates before the standalone passes
            # below can resurrect them. parse_opl_relations admits only actual
            # public_transport=stop_area relations, so unrelated/malformed
            # relations cannot suppress valid stops here.
            consumed.update(member["id"] for member in members)
            continue
        if not members:
            continue
        primary = {"properties": relation["properties"]}
        features.append(canonical_feature(relation["id"], primary, members))
        consumed.update(member["id"] for member in members)

    stations = [candidate for candidate in candidates if candidate["id"] not in consumed and candidate["kind"] in ("station", "terminal", "halt")]
    platforms = [candidate for candidate in candidates if candidate["id"] not in consumed and candidate["kind"] == "platform"]
    stop_positions = [candidate for candidate in candidates if candidate["id"] not in consumed and candidate["kind"] == "stop_position"]

    for station in stations:
        if station["id"] in consumed:
            continue
        same_stations = [station]
        if station["normalized_name"]:
            same_stations += [
                other for other in stations
                if other["id"] not in consumed and other["id"] != station["id"]
                and other["normalized_name"] == station["normalized_name"]
                and distance_meters(station, other) <= 100
            ]
        anchor = max(same_stations, key=lambda item: KIND_PRIORITY[item["kind"]])
        absorbed = list(same_stations)
        if anchor["normalized_name"]:
            absorbed += [platform for platform in platforms if platform["id"] not in consumed and platform["normalized_name"] == anchor["normalized_name"] and distance_meters(anchor, platform) <= 250]
        features.append(canonical_feature(anchor["id"], anchor, absorbed, anchor["kind"]))
        consumed.update(member["id"] for member in absorbed)

    named_platforms = defaultdict(list)
    for platform in platforms:
        if platform["id"] not in consumed and platform["normalized_name"]:
            named_platforms[platform["normalized_name"]].append(platform)
    for group in named_platforms.values():
        for cluster in connected_clusters(group, 100):
            primary = cluster[0]
            features.append(canonical_feature(primary["id"], primary, cluster))
            consumed.update(member["id"] for member in cluster)

    for platform in platforms:
        if platform["id"] not in consumed:
            features.append(canonical_feature(platform["id"], platform, [platform]))
            consumed.add(platform["id"])

    all_platforms = [candidate for candidate in candidates if candidate["kind"] == "platform"]
    for stop_position in stop_positions:
        if not stop_position["normalized_name"]:
            continue
        matched = any(
            platform["normalized_name"] == stop_position["normalized_name"]
            and distance_meters(platform, stop_position) <= 100
            for platform in all_platforms
        )
        if not matched:
            features.append(canonical_feature(stop_position["id"], stop_position, [stop_position]))

    features.sort(key=lambda feature: str(feature["id"]))
    output.write_text(json.dumps({"type": "FeatureCollection", "bbox": list(bbox), "features": features}, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8")
    metrics = {
        "candidates": len(candidates), "canonical_stops": len(features),
        "display_tiers": {str(tier): sum(feature["properties"]["display_tier"] == tier for feature in features) for tier in (15, 16, 17, 18)},
    }
    print(json.dumps(metrics, sort_keys=True))
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bbox", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--osmium", default="osmium")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    bbox = tuple(float(value) for value in args.bbox.split(","))
    prepare(args.input, args.output, args.work, bbox, args.osmium)


if __name__ == "__main__":
    main()

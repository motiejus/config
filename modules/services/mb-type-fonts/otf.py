from fontTools.ttLib import TTFont


def face_name(path):
    """Typographic name IDs 16/17 win over 1/2, which MB reuses across weights."""
    with TTFont(path, lazy=True) as font:
        name = font["name"]
        family = name.getFirstDebugName((16, 1))
        subfamily = name.getFirstDebugName((17, 2))
        if family is None or subfamily is None:
            raise SystemExit(f"{path}: no family/subfamily name record")
        return f"{family} {subfamily}"


def codepoints(path, limit):
    with TTFont(path, lazy=True) as font:
        return {c for c in font.getBestCmap() if c < limit}

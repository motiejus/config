"""Reader for llmr.glyphs PBF fontstacks (proto2)."""

def _varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7F) << s
        if not c & 0x80:
            return r, i
        s += 7


def _fields(b):
    i = 0
    while i < len(b):
        key, i = _varint(b, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(b, i)
            yield fn, v
        elif wt == 2:
            n, i = _varint(b, i)
            yield fn, b[i:i + n]
            i += n
        else:
            raise ValueError("wire type %d" % wt)


def parse_glyph(b):
    g = {"bitmap": b"", "width": 0, "height": 0}
    for fn, v in _fields(b):
        if fn == 1: g["id"] = v
        elif fn == 2: g["bitmap"] = v
        elif fn == 3: g["width"] = v
        elif fn == 4: g["height"] = v
    return g


def parse_stack(b):
    st = {"name": None, "range": None, "glyphs": {}}
    for fn, v in _fields(b):
        if fn == 1: st["name"] = v.decode()
        elif fn == 2: st["range"] = v.decode()
        elif fn == 3:
            g = parse_glyph(v)
            st["glyphs"][g["id"]] = g
    return st


def one_stack(data, what):
    stacks = [parse_stack(v) for fn, v in _fields(data) if fn == 1]
    if len(stacks) != 1:
        raise SystemExit(f"{what}: expected exactly one fontstack, got {len(stacks)}")
    return stacks[0]

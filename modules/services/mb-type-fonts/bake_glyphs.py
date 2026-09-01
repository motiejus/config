import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import otf
from glyphs_pbf import one_stack

# Mapbox SDF convention: the alpha bitmap is the glyph grown by a buffer per side.
BUFFER = 3
WORKERS = 8


def start_martin(martin, otf_dir):
    """Probe-then-bind on an ephemeral port is a race; a loser dies on bind, redraw."""
    for _ in range(5):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        proc = subprocess.Popen(
            [martin, "--font", otf_dir, "--listen-addresses", f"127.0.0.1:{port}"]
        )
        base = f"http://127.0.0.1:{port}"
        for _ in range(600):
            if proc.poll() is not None:
                break
            try:
                urllib.request.urlopen(base + "/health", timeout=1).read()
                return proc, base
            except OSError:
                time.sleep(0.1)
        proc.kill()
        proc.wait()
    sys.exit("martin never answered /health on any probed port")


def get(url):
    # A loaded host can starve actix of the request head (HTTP 408); the bake
    # must outwait the machine, not fail on it.
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code not in (408, 429, 503):
                raise
            time.sleep(2 ** attempt)
    sys.exit(f"{url}: no response in 6 attempts")


def check(what, stack, name, start, end, coverage):
    if (stack["name"], stack["range"]) != (name, f"{start}-{end}"):
        sys.exit(f"{what}: shipped as {stack['name']!r} {stack['range']!r}")
    for gid, g in stack["glyphs"].items():
        want = (g["width"] + 2 * BUFFER) * (g["height"] + 2 * BUFFER)
        if len(g["bitmap"]) != want:
            sys.exit(
                f"{what}: glyph {gid} bitmap is {len(g['bitmap'])} bytes, want {want} "
                f"for {g['width']}x{g['height']} plus a {BUFFER}px buffer"
            )
    if set(stack["glyphs"]) != coverage:
        missing = sorted(coverage - set(stack["glyphs"]))
        extra = sorted(set(stack["glyphs"]) - coverage)
        sys.exit(f"{what}: cmap says {len(coverage)} glyphs, got {len(stack['glyphs'])}; "
                 f"missing {missing[:8]}, unexpected {extra[:8]}")


def main():
    martin, otf_dir, out_dir, ranges_str = sys.argv[1:]
    ranges = [tuple(int(n) for n in r.split("-")) for r in ranges_str.split()]
    limit = max(end for _, end in ranges) + 1

    faces = {}
    for root, _dirs, leaves in os.walk(otf_dir):
        for leaf in sorted(leaves):
            if not leaf.lower().endswith(".otf"):
                continue
            path = os.path.join(root, leaf)
            name = otf.face_name(path)
            if name in faces:
                sys.exit(f"two faces are both named {name!r}: {faces[name]} and {path}")
            faces[name] = path
    if not faces:
        sys.exit(f"{otf_dir}: no .otf files")

    proc, base = start_martin(martin, otf_dir)
    try:
        served = set(json.loads(get(base + "/catalog"))["fonts"])
        if served != set(faces):
            sys.exit(f"martin serves {len(served)} faces, the tree holds {len(faces)}: "
                     f"{sorted(served ^ set(faces))[:8]}")

        covers = {
            (name, start, end): {c for c in otf.codepoints(path, limit) if start <= c <= end}
            for name, path in faces.items()
            for start, end in ranges
        }
        jobs = [(name, start, end) for name in sorted(faces) for start, end in ranges
                if covers[(name, start, end)]]

        def bake(job):
            name, start, end = job
            return get(f"{base}/font/{urllib.parse.quote(name)}/{start}-{end}")

        with ThreadPoolExecutor(WORKERS) as pool:
            for (name, start, end), body in zip(jobs, pool.map(bake, jobs)):
                os.makedirs(os.path.join(out_dir, name), exist_ok=True)
                with open(os.path.join(out_dir, name, f"{start}-{end}.pbf"), "wb") as f:
                    f.write(body)

        shipped = set()
        for name in os.listdir(out_dir):
            for leaf in os.listdir(os.path.join(out_dir, name)):
                path = os.path.join(out_dir, name, leaf)
                start, end = (int(n) for n in leaf.removesuffix(".pbf").split("-"))
                with open(path, "rb") as f:
                    body = f.read()
                what = f"{name}/{leaf}"
                stack = one_stack(body, what)
                if not stack["glyphs"]:
                    sys.exit(f"{what}: shipped with no glyphs")
                check(what, stack, name, start, end, covers.get((name, start, end), set()))
                shipped.add((name, start, end))
        if shipped != set(jobs):
            sys.exit(f"the tree holds {len(shipped)} ranges, the bake made {len(jobs)}: "
                     f"{sorted(shipped ^ set(jobs))[:8]}")

    finally:
        proc.kill()
        proc.wait()

main()

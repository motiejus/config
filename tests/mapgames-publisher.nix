# NixOS VM test for the Step-9 stateful map/search publisher
# (search-design.md §4.1, search-implementation-plan.md §Step 9).
#
# It drives the SHIPPING artifacts, not paraphrases of them:
#
#   * the publisher state machine is the one that ships inside the maps source
#     tree, exposed here as `pkgs.mapgames.publisherScript` — the exact copy the
#     mapgames-publisher module wraps in production;
#   * the vhost body is taken verbatim out of `hosts/fwminex/caddy.nix`
#     (`maps.jakstys.lt`), with only the production `tls` line removed — so the
#     `request_header -If-*` lines that implement never-304, the @identityOnly
#     matcher and the @index representation set are the ones under test;
#   * upgrades are driven by flipping `mj.services.mapgames-publisher.candidate`
#     and switching configuration, so `restartTriggers` re-runs the real seed
#     unit (the exact path a package upgrade takes);
#   * the clock is the machine's own, moved with `date -s` — no environment
#     override, so the cadence/grace/backwards-clock gates are the real ones.
#
# Covered: clean bootstrap + Caddy ordering; FAILED bootstrap on a second node
# (first-seed failure leaves caddy stopped); served 0755 / object 0644 / staging
# 0750 (captured LIVE during a real copy) and root ownership; restartTriggers
# upgrade to a candidate whose index.html AND index.html.br both changed;
# third-closure (cadence) rejection; failed upgrade; concurrent publish against
# the root lock; rollback / roll-forward; an unchanged candidate under a
# BACKWARDS clock (must stay a no-op so caddy is never blocked); and the full
# delivery policy — immutable cache, never-304 under REAL conditional requests,
# Range/206 against the raw file, a rogue `.pmtiles.br` never negotiated, br +
# Vary on a genuinely negotiated object, no-store on every index.html
# representation, CSP, and 404 for the build/registry metadata.
#
# The nix-build of this VM is DEFERRED in the implementation sandbox (the Nix
# daemon is blocked). A maintainer runs it on a machine with a working daemon,
# wired as the flake check:
#
#   nix build .#checks.x86_64-linux.mapgames-publisher
#
# or interactively:
#
#   nix build .#checks.x86_64-linux.mapgames-publisher.driverInteractive \
#     && ./result/bin/nixos-test-driver
{
  pkgs ? import <nixpkgs> { },
}:
let
  inherit (pkgs) lib;
  # The publisher state machine that ships inside maps (repo root), surfaced by
  # the config overlay as a store path. This is the production copy under test.
  publisherSrc = pkgs.mapgames.publisherScript;

  # ---------------------------------------------------------------------------
  # The SHIPPING Caddy policy, reused verbatim.
  # ---------------------------------------------------------------------------
  # hosts/fwminex/caddy.nix is a plain module function; evaluating it here and
  # reading `maps.jakstys.lt`'s extraConfig keeps this test honest — it can only
  # ever test what the host actually serves. Nix laziness means the unrelated
  # vhosts (which reference overlay packages and secrets) are never forced.
  shippingCaddy = import ../hosts/fwminex/caddy.nix {
    inherit pkgs;
    myData = import ../data.nix;
  };
  mapsVhost = shippingCaddy.services.caddy.virtualHosts."maps.jakstys.lt".extraConfig;
  # The only production-only directive is the TLS keypair (the VM speaks plain
  # HTTP on localhost). Everything else is under test unmodified.
  mapsVhostHttp = lib.concatStringsSep "\n" (
    lib.filter (l: builtins.match "[[:space:]]*tls /run/caddy/.*" l == null) (
      lib.splitString "\n" mapsVhost
    )
  );

  # ---------------------------------------------------------------------------
  # Candidate served trees mirroring build-web-graph.py's §4.1 layout:
  # hash-named immutable objects (with REAL Brotli siblings where the format is
  # negotiated), the sole mutable index.html AND its index.html.br sibling, and
  # web-graph.json declaring every representation.
  # ---------------------------------------------------------------------------
  mkCandidate =
    {
      label,
      appBody,
      searchBody,
      indexBody,
      pmtilesSeed,
      fillers ? 0,
    }:
    pkgs.runCommand "mapgames-candidate-${label}"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.brotli
        ];
      }
      ''
        python3 - "$out" <<'PY'
        import hashlib, json, os, subprocess, sys
        out = sys.argv[1]
        graph = {"page": {"mutable": True, "representations": {}},
                 "app_objects": {}, "map_objects": {}, "search_objects": {},
                 "bundles": {}, "edges": {"worker": [], "page": [], "metadata": []}}

        def brotli(path):
            subprocess.run(["brotli", "-q", "5", "-f", "-k", "-o", path + ".br", path],
                           check=True)

        def rep(path):
            data = open(path, "rb").read()
            return {"length": len(data), "sha256": hashlib.sha256(data).hexdigest()}

        def add(group_key, group_dir, role, ext, content, negotiated=False):
            h = hashlib.sha256(content).hexdigest()
            name = f"{role}-{h[:16]}.{ext}"
            d = os.path.join(out, group_dir, "objects")
            os.makedirs(d, exist_ok=True)
            p = os.path.join(d, name)
            with open(p, "wb") as fh:
                fh.write(content)
            reps = {"": {"length": len(content), "sha256": h}}
            if negotiated:
                brotli(p)
                reps[".br"] = rep(p + ".br")
            graph[group_key][name] = {
                "raw_sha256": h, "hash16": h[:16], "raw_length": len(content),
                "role": role, "representations": reps}
            return name

        os.makedirs(out, exist_ok=True)
        # A negotiated app object (has a real .br sibling) …
        add("app_objects", "app", "main", "js", ${builtins.toJSON appBody}.encode(),
            negotiated=True)
        add("search_objects", "search", "names", "mgs",
            ${builtins.toJSON searchBody}.encode(), negotiated=True)
        # … and an identity-only PMTiles object big enough for a real byte Range.
        pm = bytes(range(256)) * 16
        pm = ${builtins.toJSON pmtilesSeed}.encode() + pm[len(${builtins.toJSON pmtilesSeed}):]
        add("map_objects", "map", "catalog", "pmtiles", pm)
        # Optional filler objects: they make the staging copy long enough to be
        # observed live from outside the process.
        for i in range(${toString fillers}):
            add("app_objects", "app", f"filler{i:04d}", "js",
                (f"filler-{i}-" + "x" * 8192).encode())

        page = os.path.join(out, "index.html")
        with open(page, "wb") as fh:
            fh.write(${builtins.toJSON indexBody}.encode())
        brotli(page)              # build-web-graph.py emits $out/index.html.br
        graph["page"]["representations"][""] = rep(page)
        graph["page"]["representations"][".br"] = rep(page + ".br")

        with open(os.path.join(out, "web-graph.json"), "w") as fh:
            json.dump(graph, fh, sort_keys=True, separators=(",", ":"))
        PY
      '';

  candA = mkCandidate {
    label = "a";
    appBody = "APP-A" + lib.concatStrings (lib.genList (_: "-a") 200);
    searchBody = "SEARCH-A" + lib.concatStrings (lib.genList (_: "-s") 200);
    pmtilesSeed = "PMTILES-A";
    indexBody = "<html>release-A</html>" + lib.concatStrings (lib.genList (_: "<!--A-->") 40);
  };
  # The upgrade that a basename-keyed object filter made permanently fatal: BOTH
  # index.html and index.html.br change bytes.
  candB = mkCandidate {
    label = "b";
    appBody = "APP-B-changed" + lib.concatStrings (lib.genList (_: "-b") 200);
    searchBody = "SEARCH-B-changed" + lib.concatStrings (lib.genList (_: "-s") 200);
    pmtilesSeed = "PMTILES-A"; # unchanged pmtiles role => reused object
    indexBody = "<html>release-B</html>" + lib.concatStrings (lib.genList (_: "<!--B-->") 40);
  };
  candC = mkCandidate {
    label = "c";
    appBody = "APP-C" + lib.concatStrings (lib.genList (_: "-c") 200);
    searchBody = "SEARCH-C" + lib.concatStrings (lib.genList (_: "-s") 200);
    pmtilesSeed = "PMTILES-C";
    indexBody = "<html>release-C</html>";
  };
  # Many objects, so the 0750 staging directory exists long enough to stat it
  # from outside the publisher process.
  candStage = mkCandidate {
    label = "stage";
    appBody = "APP-STAGE";
    searchBody = "SEARCH-STAGE";
    pmtilesSeed = "PMTILES-S";
    indexBody = "<html>release-STAGE</html>";
    fillers = 384;
  };
  # A deliberately broken candidate: web-graph.json declares an object whose
  # file is absent -> the publisher must fail closed before staging.
  candBroken = pkgs.runCommand "mapgames-candidate-broken" { } ''
    mkdir -p $out/app/objects
    printf 'x' > $out/app/objects/main-0000000000000000.js
    printf '<html>broken</html>' > $out/index.html
    cat > $out/web-graph.json <<'JSON'
    {"app_objects":{"ghost-1111111111111111.js":{"hash16":"1111111111111111","raw_length":1,"raw_sha256":"1111111111111111111111111111111111111111111111111111111111111111","representations":{"":{"length":1,"sha256":"1111111111111111111111111111111111111111111111111111111111111111"}},"role":"ghost"}},"bundles":{},"edges":{"metadata":[],"page":[],"worker":[]},"map_objects":{},"page":{"mutable":true,"representations":{"":{}}},"search_objects":{}}
    JSON
  '';

  publisher = pkgs.runCommand "mapgames-publisher" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin $out/libexec
    cp ${publisherSrc} $out/libexec/mapgames-publisher.py
    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/mapgames-publisher \
      --add-flags $out/libexec/mapgames-publisher.py
  '';

  commonNode =
    { lib, ... }:
    {
      imports = [
        ../modules/services/mapgames-publisher
        # The publisher module records its unit with the base unitstatus
        # aggregator; import it so `mj.base.unitstatus.units` is defined.
        ../modules/base/unitstatus
      ];

      services.caddy = {
        enable = true;
        # The SHIPPING maps.jakstys.lt policy, verbatim.
        virtualHosts."http://localhost".extraConfig = mapsVhostHttp;
      };

      environment.systemPackages = [
        publisher
        pkgs.curl
        pkgs.util-linux # flock, for the concurrent-publish gate
      ];
      # The clock is moved with `date -s`; nothing may fight us over it.
      services.timesyncd.enable = lib.mkForce false;
    };
in
pkgs.testers.runNixOSTest {
  name = "mapgames-publisher";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ commonNode ];

      mj.services.mapgames-publisher = {
        enable = true;
        candidate = candA;
        package = publisher;
      };

      # A package upgrade in production is exactly this: the candidate store
      # path changes, restartTriggers re-runs the seed unit before caddy.
      specialisation.upgradeB.configuration = {
        mj.services.mapgames-publisher.candidate = lib.mkForce candB;
      };

      environment.etc = {
        "mapgames/candB".source = candB;
        "mapgames/candC".source = candC;
        "mapgames/candStage".source = candStage;
        "mapgames/candBroken".source = candBroken;
      };
    };

  # A node whose FIRST seed fails: caddy must never start.
  nodes.brokenboot = {
    imports = [ commonNode ];
    mj.services.mapgames-publisher = {
      enable = true;
      candidate = candBroken;
      package = publisher;
    };
  };

  testScript = ''
    import json

    start_all()

    def headers(m, path, *curl_args):
        out = m.succeed(
            "curl -sS -D - -o /dev/null " + " ".join(curl_args)
            + f" http://localhost{path}")
        status = out.splitlines()[0].strip()
        hdrs = {}
        for line in out.splitlines()[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                hdrs[k.strip().lower()] = v.strip()
        return status, hdrs

    def code(m, path, *curl_args):
        return m.succeed(
            "curl -sS -o /dev/null -w '%{http_code}' " + " ".join(curl_args)
            + f" http://localhost{path}").strip()

    with subtest("clean bootstrap: the seed ran before Caddy and current exists"):
        machine.wait_for_unit("mapgames-publisher-seed.service")
        machine.wait_for_unit("caddy.service")
        machine.succeed("test -L /var/lib/mapgames/current")
        seed_at = machine.succeed(
            "systemctl show -p ActiveEnterTimestampMonotonic --value "
            "mapgames-publisher-seed.service").strip()
        caddy_at = machine.succeed(
            "systemctl show -p ActiveEnterTimestampMonotonic --value "
            "caddy.service").strip()
        assert int(seed_at) <= int(caddy_at), "seed must activate before caddy"
        # The unit is ordered after time-sync.target so the wall-clock cadence
        # gates do not run against a pre-NTP clock when that is avoidable.
        after = machine.succeed(
            "systemctl show -p After --value mapgames-publisher-seed.service")
        assert "time-sync.target" in after, after

    with subtest("FAILED bootstrap: no current, and caddy never starts"):
        brokenboot.wait_until_succeeds(
            "systemctl is-failed mapgames-publisher-seed.service", timeout=120)
        brokenboot.fail("test -e /var/lib/mapgames/current")
        brokenboot.fail("systemctl is-active caddy.service")
        brokenboot.fail("curl -sS --max-time 5 http://localhost/")

    with subtest("first Caddy start serves the release index: 200, no-store, CSP"):
        machine.wait_for_open_port(80)
        body = machine.succeed("curl -sS http://localhost/")
        assert "release-A" in body, body
        status, h = headers(machine, "/")
        assert "200" in status, status
        assert h["cache-control"] == "no-store", h
        assert "etag" not in h and "last-modified" not in h, h
        assert "wasm-unsafe-eval" in h["content-security-policy"], h
        assert h["x-content-type-options"] == "nosniff"
        assert h["x-frame-options"] == "DENY"
        assert h["referrer-policy"] == "no-referrer"

    with subtest("root ownership and served 0755 / object 0644 modes"):
        machine.succeed("test $(stat -c%U /var/lib/mapgames/objects) = root")
        machine.succeed("test $(stat -c%a /var/lib/mapgames/objects) = 755")
        machine.succeed("test $(stat -c%a /var/lib/mapgames/releases) = 755")
        machine.succeed("test $(stat -c%a /var/lib/mapgames/state) = 755")
        machine.succeed(
            "test $(stat -c%a $(find /var/lib/mapgames/objects -type f | head -1)) = 644")
        # Every directory under the served root must be traversable by caddy.
        machine.succeed(
            "! find -L /var/lib/mapgames/current/ -type d ! -perm -005 | grep .")
        machine.succeed("test -z \"$(ls -d /var/lib/mapgames/.staging-* 2>/dev/null)\"")

    with subtest("the mutable page's .br sibling is per-release, never an object"):
        machine.fail("test -e /var/lib/mapgames/objects/index.html")
        machine.fail("test -e /var/lib/mapgames/objects/index.html.br")
        machine.succeed(
            "test -f $(readlink -f /var/lib/mapgames/current)/index.html.br")
        machine.succeed(
            "test ! -L $(readlink -f /var/lib/mapgames/current)/index.html.br")

    with subtest("every index.html representation: no-store, no validators, br"):
        for path in ["/", "/index.html", "/index.html.br"]:
            status, h = headers(machine, path, "-H 'Accept-Encoding: br'")
            assert "200" in status, (path, status)
            assert h["cache-control"] == "no-store", (path, h)
            assert "etag" not in h, (path, h)
            assert "last-modified" not in h, (path, h)
            assert h.get("content-encoding") == "br", (path, h)
        # …and identity when the client does not accept br.
        status, h = headers(machine, "/index.html")
        assert "content-encoding" not in h, h
        assert h["cache-control"] == "no-store", h

    with subtest("build manifest and registry anchor are never served"):
        assert code(machine, "/web-graph.json") == "404"
        assert code(machine, "/release-manifest.json") == "404"
        machine.fail(
            "test -e $(readlink -f /var/lib/mapgames/current)/web-graph.json")
        machine.fail(
            "test -e $(readlink -f /var/lib/mapgames/current)/release-manifest.json")
        rid = json.loads(machine.succeed(
            "cat /var/lib/mapgames/state/publisher.state.json"))["current"]["release_id"]
        machine.succeed(
            f"test -f /var/lib/mapgames/state/releases/{rid}/release-manifest.json")

    with subtest("immutable object: one-year cache + a REAL 304 on revalidation"):
        obj = machine.succeed(
            "cd /var/lib/mapgames/current && ls app/objects/main-*.js").strip()
        status, h = headers(machine, "/" + obj)
        assert "max-age=31536000" in h["cache-control"] and "immutable" in h["cache-control"]
        etag = h["etag"]
        last_mod = h["last-modified"]
        assert code(machine, "/" + obj, f"-H 'If-None-Match: {etag}'") == "304"
        assert code(machine, "/" + obj, f"-H 'If-Modified-Since: {last_mod}'") == "304"

    with subtest("the mutable page can NEVER 304, under REAL conditional requests"):
        # The very validators that just produced a 304 above are replayed at the
        # page; `request_header -If-*` must strip them so file_server cannot
        # short-circuit. A 304 here would leave a client on a stale bundle set.
        for hdr in [f"If-None-Match: {etag}", "If-None-Match: *",
                    f"If-Modified-Since: {last_mod}"]:
            assert code(machine, "/", f"-H '{hdr}'") == "200", hdr
            assert code(machine, "/index.html", f"-H '{hdr}'") == "200", hdr
        assert code(machine, "/index.html.br",
                    "-H 'If-None-Match: *'", "-H 'Accept-Encoding: br'") == "200"

    with subtest("negotiated object: Content-Encoding br + Vary"):
        status, h = headers(machine, "/" + obj, "-H 'Accept-Encoding: br'")
        assert h.get("content-encoding") == "br", h
        assert h.get("vary", "").lower() == "accept-encoding", h
        status, h = headers(machine, "/" + obj)
        assert "content-encoding" not in h, h

    with subtest("identity-only PMTiles: Range/206 from the RAW file, no Vary"):
        pm = machine.succeed(
            "cd /var/lib/mapgames/current && ls map/objects/catalog-*.pmtiles").strip()
        raw_len = machine.succeed(
            f"stat -Lc%s /var/lib/mapgames/current/{pm}").strip()
        # Plant a ROGUE .br sibling next to the object: identity-only formats are
        # enforced by a matcher, not by the absence of a sibling.
        machine.succeed(
            "printf 'ROGUE-BROTLI-GARBAGE' > "
            f"$(readlink -f /var/lib/mapgames/current)/{pm}.br")
        status, h = headers(machine, "/" + pm, "-H 'Accept-Encoding: br, gzip'")
        assert "200" in status, status
        assert "content-encoding" not in h, h
        assert "vary" not in h, h
        assert h["content-length"] == raw_len, (h, raw_len)
        status, h = headers(machine, "/" + pm,
                            "-H 'Accept-Encoding: br'", "-H 'Range: bytes=100-131'")
        assert "206" in status, status
        assert "content-encoding" not in h, h
        assert h["content-range"] == f"bytes 100-131/{raw_len}", h
        assert h["accept-ranges"] == "bytes", h
        got = machine.succeed(
            "curl -sS -H 'Accept-Encoding: br' -H 'Range: bytes=100-131' "
            f"http://localhost/{pm} | sha256sum | cut -d' ' -f1").strip()
        want = machine.succeed(
            f"dd if=/var/lib/mapgames/current/{pm} bs=1 skip=100 count=32 "
            "2>/dev/null | sha256sum | cut -d' ' -f1").strip()
        assert got == want, "206 body must come from the RAW pmtiles"
        machine.succeed(f"rm $(readlink -f /var/lib/mapgames/current)/{pm}.br")

    with subtest("third closure before the 86,400 s cadence is refused"):
        machine.fail(
            "mapgames-publisher seed --state-dir /var/lib/mapgames "
            "--candidate /etc/mapgames/candC")
        assert "release-A" in machine.succeed("curl -sS http://localhost/")
        n = machine.succeed("ls -d /var/lib/mapgames/releases/*/ | wc -l").strip()
        assert n == "1", f"a refused closure must create no root, got {n}"

    with subtest("package upgrade via restartTriggers: candidate A -> B"):
        # One day on, so the new-closure cadence and A's grace both pass.
        machine.succeed("date -s '+1 day'")
        machine.succeed(
            "/run/current-system/specialisation/upgradeB/bin/switch-to-configuration test")
        machine.wait_for_unit("mapgames-publisher-seed.service")
        # The seed unit re-ran because its restartTriggers changed …
        assert "${candB}" in machine.succeed(
            "systemctl cat mapgames-publisher-seed.service")
        body = machine.succeed("curl -sS http://localhost/")
        assert "release-B" in body, body
        st = json.loads(machine.succeed(
            "cat /var/lib/mapgames/state/publisher.state.json"))
        assert st["rollback"] is not None
        n = machine.succeed("ls -d /var/lib/mapgames/releases/*/ | wc -l").strip()
        assert n == "2", f"expected current+rollback roots, got {n}"
        # …and the page's changed .br sibling followed the page, byte for byte.
        machine.fail("test -e /var/lib/mapgames/objects/index.html.br")
        machine.succeed(
            "cmp $(readlink -f /var/lib/mapgames/current)/index.html.br "
            "${candB}/index.html.br")
        machine.succeed("systemctl is-active caddy.service")

    with subtest("idempotent restart of the seed unit is a byte-for-byte no-op"):
        before = machine.succeed("cat /var/lib/mapgames/state/publisher.state.json")
        machine.succeed("systemctl restart mapgames-publisher-seed.service")
        after = machine.succeed("cat /var/lib/mapgames/state/publisher.state.json")
        assert before == after
        assert "release-B" in machine.succeed("curl -sS http://localhost/")

    with subtest("failed upgrade leaves the previous current + Caddy untouched"):
        machine.fail(
            "mapgames-publisher seed --state-dir /var/lib/mapgames "
            "--candidate /etc/mapgames/candBroken")
        assert "release-B" in machine.succeed("curl -sS http://localhost/")
        machine.succeed("systemctl is-active caddy.service")

    with subtest("concurrent publish: the second publisher is refused"):
        # A real competing holder of the root lock, in its own unit so the test
        # driver cannot race it away.
        machine.succeed(
            "systemd-run --unit=lockhold --collect "
            "flock -x /var/lib/mapgames/state/lock -c 'sleep 60'")
        machine.wait_until_succeeds("systemctl is-active --quiet lockhold.service")
        machine.sleep(1)
        out = machine.fail(
            "mapgames-publisher seed --state-dir /var/lib/mapgames "
            "--candidate /etc/mapgames/candC 2>&1")
        assert "lock" in out.lower(), out
        assert "release-B" in machine.succeed("curl -sS http://localhost/")
        machine.succeed("systemctl stop lockhold.service")

    with subtest("rollback / roll-forward flip the live site with no third root"):
        machine.succeed("mapgames-publisher rollback --state-dir /var/lib/mapgames")
        assert "release-A" in machine.succeed("curl -sS http://localhost/")
        n = machine.succeed("ls -d /var/lib/mapgames/releases/*/ | wc -l").strip()
        assert n == "2"
        machine.succeed("mapgames-publisher roll-forward --state-dir /var/lib/mapgames")
        assert "release-B" in machine.succeed("curl -sS http://localhost/")

    with subtest("BACKWARDS clock + unchanged candidate: no-op, caddy never blocked"):
        # A dead RTC / pre-NTP boot. The candidate is byte-identical, so the seed
        # unit must succeed — failing it would block caddy.service (requiredBy)
        # and take the whole host's web serving down over an already-live release.
        lnc = json.loads(machine.succeed(
            "cat /var/lib/mapgames/state/publisher.state.json"))["last_new_closure_time"]
        machine.succeed("date -s '-2 days'")
        now = int(machine.succeed("date +%s").strip())
        assert now < lnc, f"the clock must really be behind: {now} !< {lnc}"
        before = machine.succeed("cat /var/lib/mapgames/state/publisher.state.json")
        machine.succeed("systemctl restart mapgames-publisher-seed.service")
        machine.succeed("systemctl is-active mapgames-publisher-seed.service")
        machine.succeed("systemctl is-active caddy.service")
        assert machine.succeed(
            "cat /var/lib/mapgames/state/publisher.state.json") == before
        assert "release-B" in machine.succeed("curl -sS http://localhost/")
        # …but a CHANGED candidate under that same backwards clock still refuses.
        machine.fail(
            "mapgames-publisher seed --state-dir /var/lib/mapgames "
            "--candidate /etc/mapgames/candC")
        machine.succeed("date -s '+3 days'")

    with subtest("staging is a 0750 root-only directory — captured LIVE"):
        machine.succeed(
            "systemd-run --unit=stageseed --collect "
            "$(command -v mapgames-publisher) seed "
            "--state-dir /var/lib/mapgames --candidate /etc/mapgames/candStage")
        mode = machine.succeed(
            "for i in $(seq 1 200000); do "
            "  s=$(ls -d /var/lib/mapgames/.staging-* 2>/dev/null | head -1); "
            "  if [ -n \"$s\" ]; then stat -c%a \"$s\"; exit 0; fi; "
            "  systemctl is-active --quiet stageseed.service || break; "
            "done; echo MISSED").strip()
        assert mode == "750", f"live staging mode was {mode!r}, expected 0750"
        machine.wait_until_fails("systemctl is-active --quiet stageseed.service")
        machine.succeed("systemctl show -p Result --value stageseed.service "
                        "| grep -qx success || true")
        assert "release-STAGE" in machine.succeed("curl -sS http://localhost/")
        machine.succeed("test -z \"$(ls -d /var/lib/mapgames/.staging-* 2>/dev/null)\"")
        machine.succeed("systemctl is-active caddy.service")
  '';
}

{
  lib,
  stdenvNoCC,
  fetchgit,
  fetchurl,
  runCommand,
  # Deriv 4 (checkers) foreign inputs. maps.jakstys.lt's production site/data
  # path is now zig-only (P2/P3a removed python3/jq/sqlite/strace); the only
  # non-zig test dependencies left are node (the Wasm/worker harnesses) and,
  # for the opt-in browser e2e, chromium.
  nodejs,
  chromium,
  # nixpkgs-unstable package set (exposed by the flake overlay). Stable
  # nixpkgs 26.05 only ships zig <= 0.13; maps.jakstys.lt requires zig 0.16 and
  # the zig `fetchDeps` fixed-output-derivation helper, both of which live in
  # unstable (zig.default == zig_0_16 == 0.16.0).
  pkgs-unstable,
  # Optional local lt-shelters snapshot (a directory with priedangos.jsonl,
  # kas.jsonl, refreshed-at.txt and LICENSE-DATA.md). As of maps Phase 3
  # (design §C.4 / decision 4) the snapshot left build.zig.zon: build.zig no
  # longer fetches it and REQUIRES `-Dshelters=<dir>` for every data step. null
  # therefore means "use the pinned sha256-object lt-shelters.git HEAD fetched
  # by config below" (the normal production path). Override with a checkout for
  # shelter-data iteration.
  sheltersSrc ? null,
  # null means "use $NIX_BUILD_CORES at build time" for generation workers.
  concurrency ? null,
  expansionConcurrencyCap ? 8,
  expansionBatchSize ? 256,
  # Full Lithuania PBF extent. Build time and peak memory are measured per
  # phase by the native mapmaker programs.
  bbox ? "20.618591,53.892206,26.83873,56.45329",
  # bbox ? "24.95,54.52,25.55,54.92", # Vilnius prototype/iteration area
}:

assert lib.assertMsg (
  concurrency == null || (builtins.isInt concurrency && concurrency > 0)
) "mapgames: concurrency must be a positive integer";
assert lib.assertMsg (
  builtins.isInt expansionConcurrencyCap && expansionConcurrencyCap > 0
) "mapgames: expansionConcurrencyCap must be a positive integer";
assert lib.assertMsg (
  builtins.isInt expansionBatchSize && expansionBatchSize > 0
) "mapgames: expansionBatchSize must be a positive integer";

let
  version = "260716";

  # Zig 0.16 from nixpkgs-unstable, used for dependency fetching and every
  # build. maps.jakstys.lt pins `minimum_zig_version = "0.16.0"`.
  zig = pkgs-unstable.zig_0_16;

  # ── P3b: the 4-derivation split ──────────────────────────────────────────
  # maps.jakstys.lt is now a zig+node artifact (python/jq/osmium gone from the
  # production path). This package mirrors that with four derivations:
  #
  #   Deriv 1  zigDeps   fetch FOD of build.zig.zon's dep set          [zig]
  #   Deriv 2  mapmaker  the native tools + search.wasm + publisher    [zig]
  #                      + the node-free publisher slim test. The
  #                      rarely-changing cached foundation Deriv 3/4
  #                      consume via build.zig's `-Dmapmaker` handshake.
  #   Deriv 3  site/data generate + assemble the served www / data,    [zig]
  #                      reusing Deriv 2 (`-Dmapmaker`, relink not recompile).
  #   Deriv 4  checkers  the node Wasm/worker suite (+ opt-in chromium  [zig
  #                      e2e), run over Deriv 2's binaries / Deriv 3's www. node
  #                                                                      chromium]
  #
  # `-Dmapmaker=<tree>` (build.zig, contract version 1): a prebuilt D1 tree of
  # bin/mapmaker-* + lib/search.wasm that build.zig probes (each binary reports
  # its MAPMAKER_CONTRACT_VERSION; a mismatch fails configuration loudly) and
  # consumes instead of recompiling the heavy native programs. Deriv 2 emits
  # exactly that tree; Deriv 3/4 pass it back in.

  # Whole maps.jakstys.lt source tree at a pinned revision, via fetchgit.
  #
  # git.jakstys.lt uses sha256 git objects; fetchgit's `git init` defaults to
  # sha1 and then rejects the sha256 pack. nixpkgs has no object-format knob, so
  # set git's algorithm via preFetch -- the same proven pattern as
  # pkgs/stagit-ng.nix. (`GIT_DEFAULT_HASH=sha256 nix-prefetch-git` clone-verifies
  # this flat, non-owner-qualified URL.)
  #
  # `hash` is the NAR of a `.git`-stripped checkout of mapsRev (== what fetchgit
  # produces). It is computed OFF-DAEMON per AGENTS.md §8.1
  # (`git archive <rev> | tar -x -C d && nix-hash --type sha256 --sri d`); the
  # method was validated by reproducing the previous pin (403a9ea6 ->
  # sha256-EEqDmzlPQKX9BVdXeynKX0rEGKMABvmBw1r/l27tX0g=) byte-for-byte before
  # trusting this one. Bump mapsRev + hash together when advancing the site.
  mapsRepo = "https://git.jakstys.lt/maps.jakstys.lt.git";
  # main @ 419692f (P1+P2+P3a merged: zero .py outside benchmarks, checks are
  # zig+node, one opt-in chromium e2e, publisher is a zig binary).
  mapsRev = "419692f6865049a4d1d3754a5f6346ce2d29a8e84c38b33d22456c6c42d6e656";
  mapsSrc = fetchgit {
    url = mapsRepo;
    rev = mapsRev;
    preFetch = "export GIT_DEFAULT_HASH=sha256"; # repo is sha256 object format
    hash = "sha256-6sHQKbsRQI3y1yOYO5A2j377RKF97BIG2fav52soHJk=";
  };

  # ── Deriv 1: zigDeps ──────────────────────────────────────────────────────
  # All build.zig.zon dependencies of the *root* package (native source
  # tarballs incl. Boost/SQLite/Valhalla/Tilemaker/osmium and the browser-asset
  # archives) as one fixed-output derivation. As of maps Phase 3 the Lithuania
  # PBF and lt-shelters snapshot are NO LONGER manifest deps (they left
  # build.zig.zon, design §C.4); config fetches them separately (pbfSrc /
  # shelters below) and passes them as -Dpbf/-Dshelters.
  #
  # This is nixpkgs' `zig.fetchDeps` (pkgs/development/compilers/zig/fetcher.nix)
  # inlined with ONE fix: `mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"`. Zig 0.16 writes
  # the temp download for a `.zip` dependency under $ZIG_GLOBAL_CACHE_DIR/tmp but
  # does not create that dir, and fetcher.nix `mktemp -d`s the cache without it,
  # so plain `zig.fetchDeps` fails on the sqlite `.zip` amalgamation with
  # `error: failed to create temporary zip file: FileNotFound` (confirmed on a
  # real `nix build`; `.tar.gz` deps are unaffected). TODO: drop this inline copy
  # for plain `zig.fetchDeps` once nixpkgs' fetcher.nix creates tmp/ (worth
  # upstreaming).
  #
  # `--fetch=all` (not `--fetch`) is REQUIRED: the Nix build phase has no network
  # -- only this FOD does -- so every dep Zig resolves at build time, including
  # any LAZY ones, must already be in the pre-fetched `p/`.
  #
  # `outputHash` is the NAR of the fetched `p/`, pinned from a real `nix build`
  # (config commit 893104509cc9, the Phase-4 dep set). It only needs re-deriving
  # when build.zig.zon's dependency set changes. For the 403a9ea6 -> 419692f
  # (P3b) mapsRev bump `git diff` over build.zig.zon is EMPTY, so the dep set is
  # unchanged and this value stands. Re-derive OFF-DAEMON (AGENTS.md §8.3) or
  # via lib.fakeHash on the next set-changing bump.
  zigDeps =
    runCommand "mapgames-${version}-zig-deps"
      {
        src = mapsSrc;
        nativeBuildInputs = [ zig ];
        outputHashAlgo = null;
        outputHashMode = "recursive";
        outputHash = "sha256-coWBU6PpXmiIqFY0En4pZxbwdQwOUwd25QwLiUdVcW8="; # zig-deps NAR
      }
      ''
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp" # sqlite .zip temp dir (see comment above)
        runHook unpackPhase
        cd "$sourceRoot"
        zig build --fetch=all
        mv "$ZIG_GLOBAL_CACHE_DIR/p" "$out"
      '';

  # The pre-fetched dependency set, exposed as the global cache's package store
  # so `zig build` never touches the network. The nixpkgs zig setup-hook's
  # zigConfigurePhase sets ZIG_GLOBAL_CACHE_DIR=$(mktemp -d); this link is done
  # from postConfigure, which runs *after* that (NOT postPatch, where the cache
  # dir is not set yet). The sandbox has no writable $HOME, but the hook points
  # the global cache at a writable temp dir and Zig's local cache defaults to
  # ./.zig-cache in the (writable) build dir, so no manual HOME / cache-dir
  # exports are needed.
  linkZigDeps = ''ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"'';

  # Phase-3 REQUIRED external data inputs (design §C.4 / decision 4): build.zig
  # no longer fetches these -- they left build.zig.zon -- so config supplies them
  # as -Dpbf/-Dshelters on every data/site build (a data step requested without
  # them fails loudly). `test` runs over committed fixtures and needs neither
  # (the lazyDependency-orelse grace), so these flags go ONLY to the
  # data-building invocations below, never to the Deriv 2 / Deriv 4 test paths.
  #
  # pbfSrc: the raw Lithuania .osm.pbf via fetchurl (flat file, plain download --
  # not a tarball; build.zig takes the bare .pbf path). Unchanged across the
  # 403a9ea6 -> 419692f bump (same lithuania-260716 snapshot).
  pbfSrc = fetchurl {
    url = "https://dl.jakstys.lt/maps/lithuania-260716.osm.pbf";
    hash = "sha256-7X/oYyrVG9nVF8Qeqkof1OvPUi7KrNEjnxvqkZgG5fw=";
  };

  # shelters: the lt-shelters snapshot dir. Production default = the pinned
  # sha256-object lt-shelters.git HEAD via fetchgit (verified to exist as a real
  # sha256 repo; git.jakstys.lt is sha256 object format, so preFetch sets
  # GIT_DEFAULT_HASH -- same proven pattern as mapsSrc). Override sheltersSrc with
  # a local checkout for shelter-data iteration. Bump sheltersRev + hash together.
  sheltersRev = "1131eb85efe466ca01a30bf6e761a09f5a8da9d42c28e1087540b0e0bb6f657e";
  shelters =
    if sheltersSrc != null then
      sheltersSrc
    else
      fetchgit {
        url = "https://git.jakstys.lt/lt-shelters.git";
        rev = sheltersRev;
        preFetch = "export GIT_DEFAULT_HASH=sha256"; # repo is sha256 object format
        hash = "sha256-UDz6jmf/KJvlzqKHZ5uAJHPazxP2GzZJRJVk+tQHLB4=";
      };

  # Generation-tuning flags shared by every data `zig build` invocation.
  genFlagList = [
    "-Dbbox=${bbox}"
    "-Dexpansion-concurrency-cap=${toString expansionConcurrencyCap}"
    "-Dexpansion-batch-size=${toString expansionBatchSize}"
  ];

  # The REQUIRED data inputs, added ONLY to data-building targets (site, data).
  dataInputFlags = [
    "-Dpbf=${pbfSrc}"
    "-Dshelters=${shelters}"
  ];
  dataFlagsEscaped = lib.escapeShellArgs (genFlagList ++ dataInputFlags);

  # concurrency is resolved in-shell so it can honor $NIX_BUILD_CORES when unset.
  resolveConcurrency =
    if concurrency == null then
      ''mapgames_concurrency="$NIX_BUILD_CORES"''
    else
      "mapgames_concurrency=${toString concurrency}";

  # Shared skeleton for the explicit-target zig derivations (mapmaker, data,
  # site, checkers, e2e): the nixpkgs zig setup-hook still runs its
  # zigConfigurePhase (ZIG_GLOBAL_CACHE_DIR) and we link the pre-fetched deps in
  # postConfigure; dontSetZigDefaultFlags keeps maps' own optimize/cpu selection
  # (README: the no-option build is ReleaseSafe; build.zig owns the audit).
  zigCommon = {
    inherit version;
    src = mapsSrc;
    dontSetZigDefaultFlags = true;
    postConfigure = linkZigDeps;
    dontUseZigBuild = true;
    dontUseZigInstall = true;
  };

  meta = {
    homepage = "https://maps.jakstys.lt/";
    license = with lib.licenses; [
      mit
      odbl
      bsd2
      bsd3
      ofl
    ];
    platforms = [ "x86_64-linux" ];
  };

  # ── Deriv 2: mapmaker (ZIG ALONE) ─────────────────────────────────────────
  # Compiles the native tools + lib/search.wasm (the `mapmaker` step: bin/
  # mapmaker-* + lib/*.a + lib/search.wasm), builds the Zig `mapgames-publisher`
  # CLI, and runs the node-free publisher slim test (`mapgames-publisher-test`).
  # NO data, NO node, NO browser. This is the rarely-changing cached foundation;
  # its zig-out/ IS the `-Dmapmaker` D1 tree Deriv 3/4 consume. nativeBuildInputs:
  # zig only.
  mapmaker = stdenvNoCC.mkDerivation (
    zigCommon
    // {
      pname = "mapgames-mapmaker";
      nativeBuildInputs = [ zig ];
      enableParallelBuilding = true;
      buildPhase = ''
        runHook preBuild
        zig build mapmaker mapgames-publisher mapgames-publisher-test
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        # The whole zig-out tree is the D1 `-Dmapmaker` contract: bin/mapmaker-*
        # + bin/mapgames-publisher + lib/*.a + lib/search.wasm.
        cp -r zig-out "$out"
        runHook postInstall
      '';
      meta = meta // {
        description = "maps.jakstys.lt native mapmaker D1 tree (bin/mapmaker-* + lib/search.wasm) and the Zig mapgames-publisher CLI";
      };
    }
  );

  # The mapgames-publisher command, sliced out of the Deriv 2 tree so the NixOS
  # module and its VM test wrap exactly one version-controlled binary (the Zig
  # port of the retired mapgames-publisher.py; no python interpreter anymore).
  publisher = runCommand "mapgames-publisher-bin" { } ''
    mkdir -p $out/bin
    cp ${mapmaker}/bin/mapgames-publisher $out/bin/mapgames-publisher
  '';

  # ── Deriv 3: site + data (ZIG ALONE) ──────────────────────────────────────
  # `zig build site` generates the country data and assembles the deployable
  # zig-out/www (browser vendoring + native metadata enrichment happen inside
  # the Zig site-assemble tool). It reuses Deriv 2 via -Dmapmaker (relink, not
  # recompile of the heavy native programs) and takes the two external data
  # inputs as -Dpbf/-Dshelters. nativeBuildInputs: zig only (P2 removed
  # python3/jq from the site path).
  site = stdenvNoCC.mkDerivation (
    zigCommon
    // {
      pname = "mapgames-site";
      nativeBuildInputs = [ zig ];
      # Full-country generation is single-derivation heavy work; give it the
      # whole sandbox and do not let Zig fan out beyond the requested workers.
      enableParallelBuilding = true;
      buildPhase = ''
        runHook preBuild
        ${resolveConcurrency}
        zig build site ${dataFlagsEscaped} \
          -Dmapmaker=${mapmaker} \
          -Dconcurrency="$mapgames_concurrency"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -r zig-out/www "$out"
        runHook postInstall
      '';
      meta = meta // {
        description = "Deployable maps.jakstys.lt site (zig-out/www) for a configured Lithuania snapshot region";
      };
    }
  );

  # On-demand `zig build data` (zig-out/data): the generated JSON + PMTiles,
  # validated by the data-check gate. Exposed through passthru so the raw data
  # can be built/inspected without the browser-asset assembly. Same Deriv 2
  # reuse + external inputs as `site`.
  data = stdenvNoCC.mkDerivation (
    zigCommon
    // {
      pname = "mapgames-data";
      nativeBuildInputs = [ zig ];
      buildPhase = ''
        runHook preBuild
        ${resolveConcurrency}
        zig build data ${dataFlagsEscaped} \
          -Dmapmaker=${mapmaker} \
          -Dconcurrency="$mapgames_concurrency"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cp -r zig-out/data "$out"
        runHook postInstall
      '';
      meta = meta // {
        description = "Generated JSON and PMTiles (zig-out/data) for a configured Lithuania snapshot region";
      };
    }
  );

  # ── Deriv 4: checkers (node) ──────────────────────────────────────────────
  # `zig build test` is the comprehensive fixture/unit/provider + Wasm/worker
  # battery. It runs with NO -Dpbf/-Dshelters (committed fixtures only) and
  # reuses Deriv 2's binaries via -Dmapmaker, so the heavy native programs are
  # not recompiled -- only the checkers' own glue plus the node harnesses
  # (run_wasm_goldens/search/address + check-search-worker.mjs) run. The only
  # non-zig dependency is node. NO python/jq/sqlite/strace/chromium.
  checkers = stdenvNoCC.mkDerivation (
    zigCommon
    // {
      pname = "mapgames-checkers";
      nativeBuildInputs = [
        zig
        nodejs
      ];
      buildPhase = ''
        runHook preBuild
        zig build test -Dmapmaker=${mapmaker}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        touch "$out"
        runHook postInstall
      '';
      meta = meta // {
        description = "maps.jakstys.lt node/Wasm/worker check battery (zig build test) over the Deriv 2 tree";
      };
    }
  );

  # Opt-in browser e2e: a single lean CDP-driven Chromium session over the
  # served site (`zig build e2e`). node is already a checkers dependency;
  # chromium is the only extra foreign input. Drives Deriv 3's www; reuses
  # Deriv 2 via -Dmapmaker so nothing native recompiles.
  e2e = stdenvNoCC.mkDerivation (
    zigCommon
    // {
      pname = "mapgames-e2e";
      nativeBuildInputs = [
        zig
        nodejs
        chromium
      ];
      buildPhase = ''
        runHook preBuild
        zig build e2e \
          -Dmapmaker=${mapmaker} \
          -Dchromium-bin=${chromium}/bin/chromium \
          -De2e-www=${site}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        touch "$out"
        runHook postInstall
      '';
      meta = meta // {
        description = "Opt-in headless-Chromium browser e2e over the served maps.jakstys.lt site";
      };
    }
  );
in
# The deployable artifact is Deriv 3's zig-out/www: the search-injected,
# content-addressed object graph (hash-named objects, their allowlisted Brotli
# siblings and web-graph.json, all produced by the Zig site build tools). The
# mapgames-publisher NixOS module consumes this as its `candidate`; Caddy serves
# the atomically-seeded /var/lib/mapgames/current. passthru is metadata only, so
# this override yields the SAME store path as `site` (no second heavy build).
site.overrideAttrs (_: {
  passthru = {
    inherit
      mapsSrc
      zigDeps
      mapmaker
      site
      data
      publisher
      ;
    tests = {
      inherit checkers e2e;
    };
  };
})

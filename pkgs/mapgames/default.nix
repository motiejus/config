{
  lib,
  stdenvNoCC,
  fetchgit,
  jq,
  python3,
  runCommand,
  # Test-only tools, used exclusively by the `passthru.tests.zigTest`
  # (`zig build test`) derivation. Not inputs to the production site/data path.
  nodejs,
  strace,
  sqlite,
  # nixpkgs-unstable package set (exposed by the flake overlay). Stable
  # nixpkgs 26.05 only ships zig <= 0.13; maps.jakstys.lt requires zig 0.16 and
  # the zig `fetchDeps` fixed-output-derivation helper, both of which live in
  # unstable (zig.default == zig_0_16 == 0.16.0).
  pkgs-unstable,
  # Optional local lt-shelters snapshot (a directory with priedangos.jsonl,
  # kas.jsonl, refreshed-at.txt and LICENSE-DATA.md). null keeps the pinned
  # `lt_shelters` build.zig.zon dependency in the Zig build graph (the normal
  # production path). Override with a checkout for shelter-data iteration.
  sheltersSrc ? null,
  # null means "use $NIX_BUILD_CORES at build time" for generation workers.
  concurrency ? null,
  expansionConcurrencyCap ? 8,
  expansionBatchSize ? 256,
  # Full Lithuania PBF extent. Build time and peak memory are measured per
  # phase by generate.py / the native helper.
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

  # Zig 0.16 from nixpkgs-unstable, used for both dependency fetching and the
  # build. maps.jakstys.lt pins `minimum_zig_version = "0.16.0"`.
  zig = pkgs-unstable.zig_0_16;

  # generate.py needs Shapely (which propagates GEOS) plus the CPython `_sqlite3`
  # extension (bundled in nixpkgs' python3). Tilemaker/osmium/pmtiles/Valhalla
  # are Zig-built inside `zig build` and are NOT nixpkgs inputs.
  python = python3.withPackages (ps: [ ps.shapely ]);

  # Whole maps.jakstys.lt source tree at a pinned revision, via fetchgit.
  #
  # git.jakstys.lt uses sha256 git objects; fetchgit's `git init` defaults to
  # sha1 and then rejects the sha256 pack. nixpkgs has no object-format knob, so
  # set git's algorithm via preFetch -- the same proven pattern as
  # pkgs/stagit-ng.nix. (`GIT_DEFAULT_HASH=sha256 nix-prefetch-git` clone-verifies
  # this flat, non-owner-qualified URL.)
  #
  # Bump mapsRev + hash together when advancing the site.
  # TODO(owner): confirm `hash` on the first `nix build` on a nix-daemon
  # machine. It was computed as the NAR of a `.git`-stripped clone of mapsRev
  # (== what fetchgit produces); `nix build` prints the correct value if it ever
  # drifts.
  mapsRepo = "https://git.jakstys.lt/maps.jakstys.lt.git";
  mapsRev = "3db5d7443fee6928ef0d52e1a68f01d5f61386925f0b410ea3c77e29a016396b";
  mapsSrc = fetchgit {
    url = mapsRepo;
    rev = mapsRev;
    preFetch = "export GIT_DEFAULT_HASH=sha256"; # repo is sha256 object format
    hash = "sha256-iQZyPunf/2PKDJsxrH0b4MiwRM3yUx1EAUUms/lDKjo=";
  };

  # All build.zig.zon dependencies of the *root* package (native source
  # tarballs incl. Boost/SQLite/Valhalla/Tilemaker/osmium, browser-asset
  # archives, the pinned Lithuania PBF, and lazy deps like the lt-shelters
  # snapshot) as one fixed-output derivation.
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
  # LAZY ones (lt-shelters etc.), must already be in the pre-fetched `p/`. (The
  # 12 nested `*-tests/build.zig.zon` manifests, used only by `zig build test`,
  # are a separate concern from the site/data build.)
  #
  # `outputHash` below is the NAR of the fetched `p/`, pinned from a real
  # `nix build`. Re-derive it (set to lib.fakeHash, read nix's reported value)
  # whenever build.zig.zon's dependency set changes -- typically with a mapsRev
  # bump.
  zigDeps =
    runCommand "mapgames-${version}-zig-deps"
      {
        src = mapsSrc;
        nativeBuildInputs = [ zig ];
        outputHashAlgo = null;
        outputHashMode = "recursive";
        outputHash = "sha256-maNL06Do1YVZvy0jvS1TCQkityhEJz9XmdNOOfA5Bqs="; # zig-deps NAR
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
  # exports are needed -- the manual prelude that set them is gone.
  linkZigDeps = ''ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"'';

  # Generation-tuning flags shared by every `zig build` invocation, as a Nix
  # list (fed directly to the hook via zigBuildFlags for the default `site`
  # target) and shell-escaped (for the explicit non-default data/test targets).
  genFlagList = [
    "-Dbbox=${bbox}"
    "-Dexpansion-concurrency-cap=${toString expansionConcurrencyCap}"
    "-Dexpansion-batch-size=${toString expansionBatchSize}"
  ]
  ++ lib.optional (sheltersSrc != null) "-Dshelters=${sheltersSrc}";
  genFlagsEscaped = lib.escapeShellArgs genFlagList;

  # concurrency is resolved in-shell so it can honor $NIX_BUILD_CORES when unset.
  resolveConcurrency =
    if concurrency == null then
      ''mapgames_concurrency="$NIX_BUILD_CORES"''
    else
      "mapgames_concurrency=${toString concurrency}";

  # `zig build` (default install == site) generates the country data, builds
  # every native tool from source, assembles zig-out/www (browser vendoring +
  # jq metadata enrichment happen inside build-site.sh) and runs the production
  # check gate before publishing. This is the heavy derivation.
  site = stdenvNoCC.mkDerivation {
    pname = "mapgames-site";
    inherit version;
    src = mapsSrc;

    nativeBuildInputs = [
      zig
      python
      jq
    ];

    # Full-country generation is single-derivation heavy work; give it the
    # whole sandbox and do not let Zig fan out beyond the requested workers.
    enableParallelBuilding = true;

    # Lean on the zig setup-hook: zigConfigurePhase provides ZIG_GLOBAL_CACHE_DIR
    # and zigBuildPhase runs the default `zig build` (== the site/www install).
    # Keep maps' own optimize/cpu selection (README: the no-option build is
    # ReleaseSafe; build.zig has an optimize audit and declares no `cpu` option)
    # by suppressing the hook's default -Dcpu=baseline / --release=safe flags.
    dontSetZigDefaultFlags = true;
    postConfigure = linkZigDeps;
    zigBuildFlags = genFlagList;
    # -Dconcurrency must resolve $NIX_BUILD_CORES at build time, so append it to
    # the array the hook concatenates rather than the eval-time list.
    preBuild = ''
      ${resolveConcurrency}
      zigBuildFlagsArray+=("-Dconcurrency=$mapgames_concurrency")
    '';

    # maps installs the site to zig-out/www, not via `--prefix`, so the hook's
    # default `zig build install --prefix $out` is wrong; install by hand.
    dontUseZigInstall = true;
    installPhase = ''
      runHook preInstall
      cp -r zig-out/www "$out"
      runHook postInstall
    '';

    meta = {
      description = "Deployable maps.jakstys.lt site (zig-out/www) for a configured Lithuania snapshot region";
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
  };

  # On-demand `zig build data` (zig-out/data): the generated JSON + PMTiles,
  # validated by the data-check gate. Exposed through passthru so the raw data
  # can be built/inspected without the browser-asset assembly.
  data = stdenvNoCC.mkDerivation {
    pname = "mapgames-data";
    inherit version;
    src = mapsSrc;

    nativeBuildInputs = [
      zig
      python
      jq
    ];

    # `data` is a non-default `zig build` target, so drive it explicitly; the
    # hook's zigConfigurePhase still provides ZIG_GLOBAL_CACHE_DIR (deps linked
    # in postConfigure) and dontSetZigDefaultFlags keeps maps' own optimize mode.
    dontSetZigDefaultFlags = true;
    postConfigure = linkZigDeps;
    dontUseZigBuild = true;
    buildPhase = ''
      runHook preBuild
      ${resolveConcurrency}
      zig build data ${genFlagsEscaped} -Dconcurrency="$mapgames_concurrency"
      runHook postBuild
    '';

    dontUseZigInstall = true;
    installPhase = ''
      runHook preInstall
      cp -r zig-out/data "$out"
      runHook postInstall
    '';

    meta = site.meta // {
      description = "Generated JSON and PMTiles (zig-out/data) for a configured Lithuania snapshot region";
    };
  };

  # The mapgames-publisher state machine ships inside the maps source tree now
  # (repo root), not in this config directory. Expose its store path so the
  # `mapgames-publisher` NixOS module and its VM test wrap the single
  # version-controlled copy instead of carrying a second one in config.
  publisherScript = "${mapsSrc}/mapgames-publisher.py";
in
# The deployable artifact is maps' own `zig build` output: the search-injected,
# content-addressed object graph. inject-search.py and build-web-graph.py run
# INSIDE maps' build now, so `zig-out/www` already contains the hash-named
# objects, their allowlisted Brotli siblings and web-graph.json. The
# mapgames-publisher module consumes this as its `candidate`; Caddy serves the
# atomically-seeded /var/lib/mapgames/current.
#
# No compressDrvWeb / `.etag` deployment layer is applied anymore: maps emits
# exactly the Brotli allowlist the new Caddy `precompressed br` policy
# negotiates, and the immutable objects get their revalidation validators from
# Caddy itself (a `.etag` sidecar model is incompatible with the never-304
# mutable index.html the publisher policy requires). passthru is metadata only,
# so this override yields the SAME store path as `site` (no second heavy build).
site.overrideAttrs (_: {
  passthru = {
    inherit site data publisherScript;
    tests = {
      # `zig build test` is the comprehensive production + fixture/UI/native
      # suite. It is reused against the already-generated `data` output via
      # -Dsite-data so the country is not regenerated for the checks.
      # The site-check/check fingerprint scopes additionally require the
      # test-only tools node/strace/sqlite3 in PATH (wired below).
      # TODO(owner): verify on a nix-daemon machine (never built here).
      zigTest = stdenvNoCC.mkDerivation {
        pname = "mapgames-zig-test";
        inherit version;
        src = mapsSrc;
        nativeBuildInputs = [
          zig
          python
          jq
          nodejs
          strace
          sqlite
        ];
        # `test` is a non-default target; drive it explicitly but still use the
        # hook's zigConfigurePhase (cache dir) + postConfigure dep link.
        dontSetZigDefaultFlags = true;
        postConfigure = linkZigDeps;
        dontUseZigBuild = true;
        buildPhase = ''
          runHook preBuild
          ${resolveConcurrency}
          zig build test ${genFlagsEscaped} \
            -Dconcurrency="$mapgames_concurrency" \
            -Dsite-data=${data}
          runHook postBuild
        '';
        dontUseZigInstall = true;
        installPhase = ''
          runHook preInstall
          touch "$out"
          runHook postInstall
        '';
      };
    };
  };
})

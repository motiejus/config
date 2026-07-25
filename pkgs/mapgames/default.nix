{
  lib,
  stdenvNoCC,
  cacert,
  git,
  compressDrvWeb,
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

  # Whole maps.jakstys.lt source tree at a pinned revision.
  #
  # git.jakstys.lt uses sha256 git objects, which nixpkgs' fetchgit cannot
  # clone (it runs `git init`, defaulting to sha1, then fails with "mismatched
  # algorithms"). A real `git clone` auto-negotiates the object format, so this
  # fixed-output derivation clones and checks out the rev itself -- the same
  # pattern the lt-shelters snapshot uses. `.git` is dropped so the NAR (and
  # therefore outputHash) is a function of the checked-out tree only.
  #
  # Bump mapsRev + outputHash together when advancing the site.
  # TODO(owner): recompute outputHash on a nix-daemon machine after every
  # mapsRev bump (`nix build` will print the correct sha256; or
  # `nix-prefetch-git --fetch-submodules=false <repo> <rev>` style). Left as
  # lib.fakeHash so a stale hash can never silently pass.
  mapsRepo = "https://git.jakstys.lt/maps.jakstys.lt.git";
  mapsRev = "89ec739d5cf37a1312f0f79f10702c81280334d3a326ab6bc1a02f7b4918d076";
  mapsSrc = stdenvNoCC.mkDerivation {
    name = "maps-jakstys-lt-source-${builtins.substring 0 12 mapsRev}";
    nativeBuildInputs = [
      cacert
      git
    ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = lib.fakeHash; # TODO(owner): compute on a nix-daemon machine.
    buildCommand = ''
      export GIT_SSL_CAINFO="$NIX_SSL_CERT_FILE"
      git clone --quiet ${mapsRepo} repo
      git -C repo checkout --quiet ${mapsRev}
      rm -rf repo/.git
      cp -a repo "$out"
    '';
  };

  # All build.zig.zon dependencies of the *root* package (native source
  # tarballs incl. Boost/SQLite/Valhalla/Tilemaker/osmium, browser-asset
  # archives, the pinned Lithuania PBF, and the lazy lt-shelters snapshot) as
  # one fixed-output derivation. `zig build --fetch` (fetchAll = false) is
  # sufficient: the default `zig build` (site) target only reaches root-package
  # deps. The 12 nested `*-tests/build.zig.zon` manifests are fetched by their
  # own subprocess `zig build` invocations under `zig build test`, so they are
  # out of scope here.
  #
  # TODO(owner): compute this hash on a nix-daemon machine. Either set it to
  # lib.fakeHash and read the correct value from the first `nix build` failure,
  # or run the fetcher derivation directly. It changes whenever build.zig.zon's
  # dependency set changes (i.e. together with mapsRev when deps move).
  zigDeps = zig.fetchDeps {
    pname = "mapgames";
    inherit version;
    src = mapsSrc;
    # fetchAll = false; # default; site target needs only root-package deps.
    hash = lib.fakeHash; # TODO(owner): compute on a nix-daemon machine.
  };

  # Shared prologue: point Zig's caches at build-local writable dirs (the build
  # sandbox has no writable $HOME -- the one sanctioned exception to leaving the
  # Zig cache dirs at their defaults) and expose the pre-fetched dependency set
  # as the global cache's package store so `zig build` never touches the
  # network (the build is a normal sandboxed derivation).
  zigCachePrelude = ''
    export HOME="$TMPDIR"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
    ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  # Generation-tuning flags shared by every `zig build` invocation. concurrency
  # is resolved in-shell so it can honor $NIX_BUILD_CORES when unset.
  zigGenFlags = lib.escapeShellArgs (
    [
      "-Dbbox=${bbox}"
      "-Dexpansion-concurrency-cap=${toString expansionConcurrencyCap}"
      "-Dexpansion-batch-size=${toString expansionBatchSize}"
    ]
    ++ lib.optional (sheltersSrc != null) "-Dshelters=${sheltersSrc}"
  );

  resolveConcurrency =
    if concurrency == null then
      ''mapgames_concurrency="$NIX_BUILD_CORES"''
    else
      ''mapgames_concurrency=${toString concurrency}'';

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

    buildPhase = ''
      runHook preBuild
      ${zigCachePrelude}
      ${resolveConcurrency}
      zig build ${zigGenFlags} -Dconcurrency="$mapgames_concurrency"
      runHook postBuild
    '';

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

    buildPhase = ''
      runHook preBuild
      ${zigCachePrelude}
      ${resolveConcurrency}
      zig build data ${zigGenFlags} -Dconcurrency="$mapgames_concurrency"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r zig-out/data "$out"
      runHook postInstall
    '';

    meta = site.meta // {
      description = "Generated JSON and PMTiles (zig-out/data) for a configured Lithuania snapshot region";
    };
  };

  writeEtags = ''
    find "$out" -type f ! -name '*.etag' | while read -r file; do
      hash=$(sha256sum "$file")
      printf '"%s"' "''${hash:0:32}" > "$file.etag"
    done
  '';

  compressed = compressDrvWeb site {
    # Never add "pmtiles" here (or serve pmtiles pre-encoded): pmtiles.js
    # issues HTTP Range requests that must address identity bytes. A .br/.gz
    # sidecar would let the web server satisfy ranges over encoded bytes,
    # which decodes to silent tile corruption.
    extraFormats = [
      "geojson"
      "pbf"
    ];
  };
in
runCommand "mapgames-${version}"
  {
    # compressDrvWeb transforms the files but does not carry custom passthru.
    # Keep the compressed payload while carrying the package identity/tests
    # through the final etag wrapper. Static compression + ETags are the
    # deployment layer: maps.jakstys.lt's `zig build` deliberately does not
    # emit them, so they are produced here.
    pname = "mapgames";
    inherit version;
    inherit (site) meta;
    passthru = {
      inherit site data;
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
          buildPhase = ''
            runHook preBuild
            ${zigCachePrelude}
            ${resolveConcurrency}
            zig build test ${zigGenFlags} \
              -Dconcurrency="$mapgames_concurrency" \
              -Dsite-data=${data}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            touch "$out"
            runHook postInstall
          '';
        };
      };
    };
  }
  ''
    cp -r --no-preserve=mode ${compressed} "$out"
    ${writeEtags}
  ''

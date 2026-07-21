{
  lib,
  stdenv,
  stdenvNoCC,
  cacert,
  fetchurl,
  git,
  boost,
  compressDrvWeb,
  jq,
  libtiff,
  osmium-tool,
  nodejs,
  pkg-config,
  pmtiles,
  python3,
  rapidjson,
  runCommand,
  sqlite,
  tilemaker,
  valhalla,
  writeShellScript,
  # Pinned lt-shelters snapshot (a directory with priedangos.jsonl, kas.jsonl,
  # and refreshed-at.txt). null uses the fetched default pinned below; override
  # with a local checkout or another derivation for iteration or air-gapped
  # builds.
  sheltersSrc ? null,
  # null means "use $NIX_BUILD_CORES at build time" for the general pipeline.
  # Expansion worker-count policy belongs here; generate.py simply uses the
  # helper and worker count it is passed.
  concurrency ? null,
  expansionConcurrencyCap ? 8,
  expansionBatchSize ? 256,
  # Full Lithuania PBF extent. Build time and peak memory are measured per
  # phase by generate.py/the native helper.
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
  sourceUrl = "https://dl.jakstys.lt/maps/lithuania-260716.osm.pbf";
  expansionArenaCap = expansionConcurrencyCap;
  lithuaniaPbf = fetchurl {
    name = "lithuania-260716.osm.pbf";
    url = sourceUrl;
    hash = "sha256-7X/oYyrVG9nVF8Qeqkof1OvPUi7KrNEjnxvqkZgG5fw=";
  };

  # Pinned snapshot of the official PAGD shelter datasets, produced by the
  # lt-shelters service (modules/services/lt-shelters). The repo uses sha256
  # git objects, which nixpkgs' fetchgit cannot clone (it runs `git init`,
  # defaulting to sha1, then fails with "mismatched algorithms"). A real
  # `git clone` auto-negotiates the object format, so this fixed-output
  # derivation clones and checks out the rev itself. outputHash is the NAR of
  # only the three files generate.py consumes, so README/LICENSE churn in the
  # source repo does not invalidate it — only a data or refresh-time change
  # bumped via sheltersRev does. Bump sheltersRev + outputHash together, the
  # same maintenance the pinned PBF above needs.
  sheltersRepo = "https://git.jakstys.lt/lt-shelters.git";
  sheltersRev = "1131eb85efe466ca01a30bf6e761a09f5a8da9d42c28e1087540b0e0bb6f657e";
  pinnedShelters = stdenvNoCC.mkDerivation {
    name = "lt-shelters-snapshot-${builtins.substring 0 12 sheltersRev}";
    nativeBuildInputs = [
      cacert
      git
    ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-kdGTxdfmPpVNT4a344uK9I0j/4HfeDCZX9jee8UwKGw=";
    buildCommand = ''
      export GIT_SSL_CAINFO="$NIX_SSL_CERT_FILE"
      git clone --quiet ${sheltersRepo} repo
      git -C repo checkout --quiet ${sheltersRev}
      mkdir -p "$out"
      install -m 0644 \
        repo/priedangos.jsonl \
        repo/kas.jsonl \
        repo/refreshed-at.txt \
        "$out/"
    '';
  };
  shelters = if sheltersSrc == null then pinnedShelters else sheltersSrc;

  maplibreVersion = "5.24.0";
  maplibreSource = fetchurl {
    url = "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-${maplibreVersion}.tgz";
    hash = "sha256-XL+DwyjJ05yyTj8s78m0B9ad0QS6C0HoTAv7sxxE4oM=";
  };

  pmtilesJsVersion = "4.4.1";
  pmtilesJsSource = fetchurl {
    url = "https://registry.npmjs.org/pmtiles/-/pmtiles-${pmtilesJsVersion}.tgz";
    hash = "sha256-4n78Cv4iIDJh4Pc0a8MhNszZHXLnw+0UxKfsZtHkiXw=";
  };
  pmtilesLicense = fetchurl {
    url = "https://raw.githubusercontent.com/protomaps/PMTiles/0cebcaeade40034b86facb6e7da4ec726b9053fb/LICENSE";
    hash = "sha256-A3HDjzOINff8E+1xF289khROIsi3NqMcztV62762R7M=";
  };

  protomapsBasemapsVersion = "5.7.2";
  protomapsBasemapsSource = fetchurl {
    url = "https://registry.npmjs.org/@protomaps/basemaps/-/basemaps-${protomapsBasemapsVersion}.tgz";
    hash = "sha256-LV1BspzdI2T3CSrUOb2dFwtPOMvsiFjO++hND5gSXOY=";
  };
  protomapsBasemapsLicense = fetchurl {
    url = "https://raw.githubusercontent.com/protomaps/basemaps/3ea8293a28131c3dc63f1bb20827bdb8a76df06f/LICENSE.md";
    hash = "sha256-dPl1z+3RaAmMQ7XP1uWH5AYEaExP/Ow+kNJLOwnAYbA=";
  };

  basemapAssetsRevision = "028c18f713baecad011301ff7a69acc39bcc2ae7";
  basemapAssetsSource = fetchurl {
    url = "https://github.com/protomaps/basemaps-assets/archive/${basemapAssetsRevision}.tar.gz";
    hash = "sha256-V+QOjFEr2AQtCjolHxnQ0chSOtljxmbDxmQ7raTcktA=";
  };

  python = python3.withPackages (ps: [ ps.shapely ]);
  valhallaExpand = stdenv.mkDerivation {
    pname = "mapgames-valhalla-expand";
    version = "260716";

    dontUnpack = true;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      boost
      libtiff
      rapidjson
      sqlite
      valhalla
    ];

    buildPhase = ''
      runHook preBuild

      ln -s ${./destination-relations.hh} destination-relations.hh
      ln -s ${./destination-lookup-finalize.hh} destination-lookup-finalize.hh
      $CXX -std=c++20 -O2 -pthread ${./valhalla-expand.cc} \
        ${./destination-lookup-native.cc} \
        -I. \
        -lsqlite3 \
        -o mapgames-valhalla-expand \
        $(pkg-config --cflags --libs libvalhalla)

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dm755 mapgames-valhalla-expand "$out/bin/mapgames-valhalla-expand"

      runHook postInstall
    '';
  };
  valhallaExpandRunner = writeShellScript "mapgames-valhalla-expand-runner" ''
    export MALLOC_ARENA_MAX=${toString expansionArenaCap}
    exec ${valhallaExpand}/bin/mapgames-valhalla-expand "$@"
  '';
  writeEtags = ''
    find "$out" -type f ! -name '*.etag' | while read -r file; do
      hash=$(sha256sum "$file")
      printf '"%s"' "''${hash:0:32}" > "$file.etag"
    done
  '';
  detailFixtureCheck = runCommand "mapgames-detail-fixture-check" { } ''
    ${python3}/bin/python ${./check-detail-fixture.py} \
      --config ${./detail.json} \
      --fixture ${./testdata/detail.osm} \
      --index ${./index.html} \
      --osmium ${osmium-tool}/bin/osmium \
      --process ${./detail.lua} \
      --tilemaker ${tilemaker}/bin/tilemaker
    touch "$out"
  '';
  inspectorFixtureCheck = runCommand "mapgames-inspector-fixture-check" { } ''
    ${python3}/bin/python ${./check-inspector-fixture.py} \
      --config ${./inspector.json} \
      --fixture ${./testdata/inspector.osm} \
      --osmium ${osmium-tool}/bin/osmium \
      --process ${./inspector.lua} \
      --tilemaker ${tilemaker}/bin/tilemaker
    touch "$out"
  '';
  catalogCheck = runCommand "mapgames-catalog-check" { } ''
    ${python3}/bin/python ${./check-catalog.py} \
      --catalog-tool ${./catalog.py} \
      --destination-tool ${./destination-lookup.py} \
      --destination-native-tool ${valhallaExpand}/bin/mapgames-valhalla-expand \
      --generate ${./generate.py} \
      --pmtiles ${pmtiles}/bin/pmtiles
    touch "$out"
  '';
  destinationLookupCheck = runCommand "mapgames-destination-lookup-check" { } ''
    ${python3}/bin/python ${./check-destination-lookup.py} \
      --tool ${./destination-lookup.py} \
      --native-tool ${valhallaExpand}/bin/mapgames-valhalla-expand \
      --catalog-tool ${./catalog.py} \
      --coarsen-tool ${./coarsen.py} \
      --coarsen-check-tool ${./check-lowzoom-coarsen.py}
    touch "$out"
  '';
  transitFixtureCheck = runCommand "mapgames-transit-fixture-check" { } ''
    ${python3}/bin/python ${./check-transit-fixture.py} \
      --fixture ${./testdata/transit.osm} \
      --index ${./index.html} \
      --osmium ${osmium-tool}/bin/osmium \
      --transit ${./transit.py}
    touch "$out"
  '';
  inspectorUiCheck = runCommand "mapgames-inspector-ui-check" { } ''
    ${python3}/bin/python ${./check-inspector-ui.py} --index ${./index.html}
    touch "$out"
  '';
  roadHitUiCheck = runCommand "mapgames-road-hit-ui-check" { } ''
    ${python3}/bin/python ${./check-road-hit-ui.py} --index ${./index.html}
    touch "$out"
  '';
  cameraBoundsCheck = runCommand "mapgames-camera-bounds-check" { } ''
    ${python3}/bin/python ${./check-camera-bounds.py} --index ${./index.html}
    touch "$out"
  '';
  geolocationUiCheck = runCommand "mapgames-geolocation-ui-check" { } ''
    ${python3}/bin/python ${./check-geolocation-ui.py} --index ${./index.html}
    touch "$out"
  '';
  waterUiCheck = runCommand "mapgames-water-ui-check" { } ''
    ${python3}/bin/python ${./check-water-ui.py} --index ${./index.html}
    touch "$out"
  '';
  catalogClientCheck =
    runCommand "mapgames-catalog-client-check"
      {
        nativeBuildInputs = [ nodejs ];
      }
      ''
        node ${./check-catalog-pages.js} ${./catalog-pages.js}
        node ${./check-destination-relations.js} \
          ${./destination-relations.js} ${./catalog-pages.js}
        node ${./check-review-ui-state.js} ${./review-ui-state.js} ${./index.html}
        ${python3}/bin/python ${./check-catalog-ui.py} \
          --index ${./index.html} \
          --client ${./catalog-pages.js}
        ${python3}/bin/python ${./check-shared-destination-ui.py} \
          --index ${./index.html} \
          --resolver ${./destination-relations.js} \
          --catalog-client ${./catalog-pages.js}
        touch "$out"
      '';
  data = stdenvNoCC.mkDerivation {
    pname = "mapgames-data";
    version = "260716";

    dontUnpack = true;

    nativeBuildInputs = [
      osmium-tool
      pmtiles
      python
      tilemaker
      valhalla
      valhallaExpand
    ];

    buildPhase = ''
      runHook preBuild

      mapgames_concurrency=${if concurrency == null then "\"$NIX_BUILD_CORES\"" else toString concurrency}
      mapgames_expansion_concurrency="$mapgames_concurrency"
      if (( mapgames_expansion_concurrency > ${toString expansionConcurrencyCap} )); then
        mapgames_expansion_concurrency=${toString expansionConcurrencyCap}
      fi
      export PYTHONPATH="${valhalla}/${python3.sitePackages}"
      python ${./generate.py} \
        --pbf ${lithuaniaPbf} \
        --bbox ${lib.escapeShellArg bbox} \
        --concurrency "$mapgames_concurrency" \
        --expansion-concurrency "$mapgames_expansion_concurrency" \
        --expansion-batch-size ${toString expansionBatchSize} \
        --basemap-config ${./basemap.json} \
        --basemap-process ${./basemap.lua} \
        --detail-config ${./detail.json} \
        --detail-process ${./detail.lua} \
        --inspector-config ${./inspector.json} \
        --inspector-process ${./inspector.lua} \
        --transit-tool ${./transit.py} \
        --geojson-process ${./geojson.lua} \
        --catalog-tool ${./catalog.py} \
        --destination-lookup-tool ${./destination-lookup.py} \
        --destination-lookup-native-tool ${valhallaExpand}/bin/mapgames-valhalla-expand \
        --pmtiles-cli-version ${lib.escapeShellArg pmtiles.version} \
        --tilemaker-version ${lib.escapeShellArg tilemaker.version} \
        --valhalla-version ${lib.escapeShellArg valhalla.version} \
        --expansion-helper ${valhallaExpandRunner} \
        --coarsen-tool ${./coarsen.py} \
        --osm-source-url ${lib.escapeShellArg sourceUrl} \
        --shelter-priedangos ${shelters}/priedangos.jsonl \
        --shelter-kas ${shelters}/kas.jsonl \
        --shelter-refreshed-at ${shelters}/refreshed-at.txt \
        --output generated

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp generated/*.json generated/*.pmtiles "$out/"
      ${writeEtags}

      runHook postInstall
    '';

    passthru = {
      inherit bbox lithuaniaPbf;
      tests = {
        catalog = catalogCheck;
        catalogClient = catalogClientCheck;
        destinationLookup = destinationLookupCheck;
        cameraBounds = cameraBoundsCheck;
        detailFixture = detailFixtureCheck;
        geolocationUi = geolocationUiCheck;
        inspectorFixture = inspectorFixtureCheck;
        inspectorUi = inspectorUiCheck;
        roadHitUi = roadHitUiCheck;
        transitFixture = transitFixtureCheck;
        waterUi = waterUiCheck;
      };
    };

    meta = {
      description = "Everyday-service reachable networks and vector tiles for a configured Lithuania snapshot region";
      homepage = "https://www.openstreetmap.org/";
      license = with lib.licenses; [
        mit
        odbl
        bsd2
        bsd3
        ofl
      ];
      platforms = lib.platforms.linux;
    };
  };

  www = stdenvNoCC.mkDerivation {
    pname = "mapgames";
    version = "260716";

    dontUnpack = true;
    dontBuild = true;

    nativeBuildInputs = [ jq ];

    installPhase = ''
      runHook preInstall

      mkdir -p \
        "$out/assets/fonts" \
        "$out/assets/sprites" \
        vendor-maplibre \
        vendor-pmtiles \
        vendor-protomaps-basemaps \
        vendor-basemap-assets
      for file in ${data}/*; do
        if test "''${file##*/}" != metadata.json && test "''${file##*/}" != metadata.json.etag; then
          ln -s "$file" "$out/"
        fi
      done
      jq \
        --arg renderer "maplibre-gl" \
        --arg renderer_version ${lib.escapeShellArg maplibreVersion} \
        --arg pmtiles_js_version ${lib.escapeShellArg pmtilesJsVersion} \
        --arg style "@protomaps/basemaps" \
        --arg style_version ${lib.escapeShellArg protomapsBasemapsVersion} \
        '.basemap += {
          renderer: $renderer,
          renderer_version: $renderer_version,
          pmtiles_js_version: $pmtiles_js_version,
          style: $style,
          style_version: $style_version
        }' \
        ${data}/metadata.json > "$out/metadata.json"
      cp ${./index.html} "$out/index.html"
      cp ${./catalog-pages.js} "$out/assets/catalog-pages.js"
      cp ${./destination-relations.js} "$out/assets/destination-relations.js"
      cp ${./review-ui-state.js} "$out/assets/review-ui-state.js"

      tar -xzf ${maplibreSource} -C vendor-maplibre --strip-components=1 \
        package/LICENSE.txt \
        package/dist/maplibre-gl.css \
        package/dist/maplibre-gl-csp.js \
        package/dist/maplibre-gl-csp-worker.js
      cp vendor-maplibre/dist/maplibre-gl.css \
        vendor-maplibre/dist/maplibre-gl-csp.js \
        vendor-maplibre/dist/maplibre-gl-csp-worker.js \
        "$out/assets/"
      cp vendor-maplibre/LICENSE.txt "$out/LICENSE.maplibre-gl"

      tar -xzf ${pmtilesJsSource} -C vendor-pmtiles --strip-components=1 \
        package/dist/pmtiles.js
      cp vendor-pmtiles/dist/pmtiles.js "$out/assets/"
      cp ${pmtilesLicense} "$out/LICENSE.pmtiles"

      tar -xzf ${protomapsBasemapsSource} -C vendor-protomaps-basemaps \
        --strip-components=1 package/dist/basemaps.js
      cp vendor-protomaps-basemaps/dist/basemaps.js "$out/assets/"
      cp ${protomapsBasemapsLicense} "$out/LICENSE.protomaps-basemaps"

      tar -xzf ${basemapAssetsSource} -C vendor-basemap-assets --strip-components=1
      cp -r \
        vendor-basemap-assets/fonts/"Noto Sans Italic" \
        vendor-basemap-assets/fonts/"Noto Sans Medium" \
        vendor-basemap-assets/fonts/"Noto Sans Regular" \
        "$out/assets/fonts/"
      cp vendor-basemap-assets/sprites/v4/light* "$out/assets/sprites/"
      # Style construction relies on these exact pinned pictograms at both
      # device pixel ratios. Fail the derivation here instead of rendering an
      # unexplained blank marker when an upstream atlas changes.
      for sprite in \
        "$out/assets/sprites/light.json" \
        "$out/assets/sprites/light@2x.json"; do
        jq -e '
          has("arrow") and has("bench") and has("park") and has("toilets") and
          has("train_station") and has("ferry_terminal") and
          has("capital") and has("townspot") and
          has("generic_shield-1char") and has("generic_shield-2char") and
          has("generic_shield-3char") and has("generic_shield-4char") and
          has("generic_shield-5char")
        ' "$sprite" >/dev/null
      done
      cp vendor-basemap-assets/fonts/OFL.txt "$out/LICENSE.fonts-OFL"
      cp vendor-basemap-assets/README.md "$out/LICENSE.basemap-assets-README"
      ${writeEtags}

      runHook postInstall
    '';

    passthru = {
      inherit data;
      inherit (data) lithuaniaPbf tests;
    };

    meta = {
      description = "Everyday-service reachable networks and interactive map for a configured Lithuania snapshot region";
      homepage = "https://www.openstreetmap.org/";
      license = with lib.licenses; [
        mit
        odbl
        bsd2
        bsd3
        ofl
      ];
      platforms = lib.platforms.linux;
    };
  };

  compressed = compressDrvWeb www {
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
runCommand "${compressed.name}-etag"
  {
    # compressDrvWeb transforms the files but does not preserve custom
    # passthru attributes. Keep the compressed payload below while carrying
    # the web package identity/tests through the final etag wrapper.
    inherit (www)
      meta
      passthru
      pname
      version
      ;
  }
  ''
    cp -r --no-preserve=mode ${compressed} $out
    ${writeEtags}
  ''

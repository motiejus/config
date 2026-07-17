{
  lib,
  stdenvNoCC,
  fetchurl,
  compressDrvWeb,
  jq,
  osmium-tool,
  python3,
  runCommand,
  tilemaker,
  valhalla,
  concurrency ? 4,
  smoothingMeters ? 12,
  simplifyMeters ? 5,
}:

assert lib.assertMsg (
  builtins.isInt concurrency && concurrency > 0
) "mapgames: concurrency must be a positive integer";
assert lib.assertMsg (smoothingMeters >= 0) "mapgames: smoothingMeters must not be negative";
assert lib.assertMsg (simplifyMeters >= 0) "mapgames: simplifyMeters must not be negative";

let
  sourceUrl = "https://dl.jakstys.lt/maps/lithuania-260716.osm.pbf";
  lithuaniaPbf = fetchurl {
    name = "lithuania-260716.osm.pbf";
    url = sourceUrl;
    hash = "sha256-7X/oYyrVG9nVF8Qeqkof1OvPUi7KrNEjnxvqkZgG5fw=";
  };

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
  writeEtags = ''
    find "$out" -type f ! -name '*.etag' | while read -r file; do
      hash=$(sha256sum "$file")
      printf '"%s"' "''${hash:0:32}" > "$file.etag"
    done
  '';
  data = stdenvNoCC.mkDerivation {
    pname = "mapgames-data";
    version = "260716";

    dontUnpack = true;

    nativeBuildInputs = [
      osmium-tool
      python
      tilemaker
      valhalla
    ];

    buildPhase = ''
      runHook preBuild

      export PYTHONPATH="${valhalla}/${python3.sitePackages}"
      python ${./generate.py} \
        --pbf ${lithuaniaPbf} \
        --concurrency ${toString concurrency} \
        --basemap-config ${./basemap.json} \
        --basemap-process ${./basemap.lua} \
        --coverage-process ${./coverage.lua} \
        --tilemaker-version ${lib.escapeShellArg tilemaker.version} \
        --valhalla-version ${lib.escapeShellArg valhalla.version} \
        --osm-source-url ${lib.escapeShellArg sourceUrl} \
        --smoothing-meters ${toString smoothingMeters} \
        --simplify-meters ${toString simplifyMeters} \
        --output generated

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp generated/*.geojson generated/*.pmtiles generated/metadata.json "$out/"
      ${writeEtags}

      runHook postInstall
    '';

    passthru = {
      inherit lithuaniaPbf;
      contourMinutes = [
        5
        10
        20
      ];
    };

    meta = {
      description = "Lithuania cafe walking-time routing data and vector tiles";
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
      cp vendor-basemap-assets/fonts/OFL.txt "$out/LICENSE.fonts-OFL"
      cp vendor-basemap-assets/README.md "$out/LICENSE.basemap-assets-README"
      ${writeEtags}

      runHook postInstall
    '';

    passthru = {
      inherit data;
      inherit (data) lithuaniaPbf contourMinutes;
    };

    meta = {
      description = "Lithuania cafe walking-time coverage polygons and demo map";
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
    extraFormats = [
      "geojson"
      "pbf"
    ];
  };
in
runCommand "${compressed.name}-etag"
  {
    inherit (compressed)
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

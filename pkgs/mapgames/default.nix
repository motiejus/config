{
  lib,
  stdenvNoCC,
  fetchurl,
  osmium-tool,
  python3,
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

  leafletVersion = "1.9.4";
  leafletSource = fetchurl {
    url = "https://registry.npmjs.org/leaflet/-/leaflet-${leafletVersion}.tgz";
    hash = "sha256-hMZaJW5QZXiW9UwzvYV7aEnr6UyBeAO+gYvzKj3eC3c=";
  };

  protomapsLeafletVersion = "5.1.0";
  protomapsLeafletSource = fetchurl {
    url = "https://registry.npmjs.org/protomaps-leaflet/-/protomaps-leaflet-${protomapsLeafletVersion}.tgz";
    hash = "sha256-C0WwjQ5vfTmBZBXb5oIdBVbnmX7HFu0BIzBcwf5aP9g=";
  };

  python = python3.withPackages (ps: [ ps.shapely ]);
in
stdenvNoCC.mkDerivation {
  pname = "mapgames";
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
      --tilemaker-version ${lib.escapeShellArg tilemaker.version} \
      --renderer-version ${lib.escapeShellArg protomapsLeafletVersion} \
      --valhalla-version ${lib.escapeShellArg valhalla.version} \
      --osm-source-url ${lib.escapeShellArg sourceUrl} \
      --smoothing-meters ${toString smoothingMeters} \
      --simplify-meters ${toString simplifyMeters} \
      --output generated

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/assets" vendor-leaflet vendor-protomaps
    cp ${./index.html} "$out/index.html"
    cp generated/*.geojson generated/*.pmtiles generated/metadata.json "$out/"

    tar -xzf ${leafletSource} -C vendor-leaflet --strip-components=1 \
      package/LICENSE package/dist
    cp vendor-leaflet/dist/leaflet.css vendor-leaflet/dist/leaflet.js "$out/assets/"
    cp -r vendor-leaflet/dist/images "$out/assets/"
    cp vendor-leaflet/LICENSE "$out/LICENSE.leaflet"

    tar -xzf ${protomapsLeafletSource} -C vendor-protomaps --strip-components=1 \
      package/LICENSE package/dist/protomaps-leaflet.js
    cp vendor-protomaps/dist/protomaps-leaflet.js "$out/assets/"
    cp vendor-protomaps/LICENSE "$out/LICENSE.protomaps-leaflet"

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
    description = "Lithuania cafe walking-time coverage polygons and demo map";
    homepage = "https://www.openstreetmap.org/";
    license = with lib.licenses; [
      mit
      odbl
      bsd2
      bsd3
    ];
    platforms = lib.platforms.linux;
  };
}

{
  lib,
  martin,
  python3,
  runCommand,
  unpacked,
  version,
}:
let
  ranges = [
    "0-255"
    "256-511"
    "512-767"
    "768-1023"
    "1024-1279"
    "1280-1535"
    "1536-1791"
    "8192-8447"
  ];

in
runCommand "mb-type-${version}"
  {
    nativeBuildInputs = [
      martin
      (python3.withPackages (p: [ p.fonttools ]))
    ];
    ranges = lib.concatStringsSep " " ranges;
  }
  ''
    mkdir -p $out/glyphs
    for format in otf ttf woff2; do
      ln -sT "${unpacked}/$format" "$out/$format"
    done

    cp ${./bake_glyphs.py} bake_glyphs.py
    cp ${./glyphs_pbf.py} glyphs_pbf.py
    cp ${./otf.py} otf.py
    python3 bake_glyphs.py \
      ${martin}/bin/martin ${unpacked}/otf $out/glyphs "$ranges"

    cat >$out/glyphs/LICENSE <<'EOF'
    The MB Type faces in this tree, and the SDF glyph ranges baked from them
    under glyphs/, are licensed from MB Type (https://mbtype.com) to a single
    user. They may not be redistributed.
    EOF
    ln -s glyphs/LICENSE $out/LICENSE
  ''

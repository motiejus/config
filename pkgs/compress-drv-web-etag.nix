{
  lib,
  compressDrvWeb,
  brotli,
  runCommand,
}:
# drv's files with a precompressed .br sibling each (caddy file_server's
# `precompressed br`) and a content-hash .etag sidecar per file and variant
# (`etag_file_extensions .etag`): caddy derives no etag from nix-store epoch
# mtimes, so without them a no-cache page could never 304.
drv:
{
  extraFormats ? [ ],
}:
let
  www = compressDrvWeb drv {
    inherit extraFormats;
    compressors = {
      br = "${lib.getExe brotli} --keep --no-copy-stat {}";
    };
  };
in
runCommand "${www.name}-etag" { } ''
  cp -rL --no-preserve=mode ${www} $out
  find $out -type f ! -name '*.etag' | while read -r f; do
    h=$(sha256sum "$f") # separate assignment: a failure aborts the build
    printf '"%s"' "''${h:0:32}" > "$f.etag"
  done
''

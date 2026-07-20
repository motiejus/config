{
  lib,
  zig_0_16,
  stdenvNoCC,
  fetchgit,
  compressDrvWeb,
  runCommand,
}:

let
  # Static assets get precompressed .gz/.br/.zst siblings (the wasm is the
  # big one); caddy serves them via file_server's `precompressed`.
  www = compressDrvWeb (stdenvNoCC.mkDerivation {
    pname = "stagit-ng";
    version = "0-unstable-2026-07-04";

    src = fetchgit {
      # TODO: flatten to https://git.jakstys.lt/stagit-ng.git once the flat
      # namespace is deployed — this owner-qualified form then only works
      # via the temporary @oldclone redirect and blocks its removal.
      url = "https://git.jakstys.lt/motiejus/stagit-ng.git";
      rev = "de12acd341d28fa45f5759a0286b5c78bae5f2927c868b06301d1c427851ce9a";
      # The repo is in sha256 object format; fetchgit's `git init` defaults
      # to sha1 and then rejects the sha256 pack ("pack is corrupted").
      # nixpkgs has no object-format knob, so set git's via preFetch.
      preFetch = "export GIT_DEFAULT_HASH=sha256";
      hash = "sha256-gdJTfNZfzRPt3g0ZDo0T5jD5dBXO6wffEaoj5cmlRpw=";
    };

    nativeBuildInputs = [ zig_0_16 ];

    dontConfigure = true;
    dontInstall = true;

    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      # stagit-ng is path-routed with no build-time switch; the git vhost
      # provides the SPA fallback app routes need by importing the routing
      # contract, deploy/Caddyfile.snippet — shipped here straight from the
      # source tree (build.zig only builds; it does not install deploy/).
      zig build --release=fast -p $out
      cp -r deploy $out/deploy
      runHook postBuild
    '';

    meta = {
      description = "Client-side git repository browser (wasm) over dumb HTTP";
      homepage = "https://git.jakstys.lt/stagit-ng";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }) { extraFormats = [ "wasm" ]; };
in
# Content-hash .etag sidecar per served file (compressed variants get
# their own), used by the git vhost via file_server's
# etag_file_extensions: caddy refuses to derive its native (mtime, size)
# etag from nix-store epoch mtimes (usefulModTime) and then sends no
# validator at all, so without these sidecars a no-cache frontend could
# never 304 — every load would re-download full bodies. cp -rL flattens
# the compressDrvWeb symlinks so sidecars sit next to real files.
runCommand "${www.name}-etag" { } ''
  cp -rL --no-preserve=mode ${www} $out
  find $out -type f ! -name '*.etag' | while read -r f; do
    h=$(sha256sum "$f") # separate assignment: a failure aborts the build
    printf '"%s"' "''${h:0:32}" > "$f.etag"
  done
''

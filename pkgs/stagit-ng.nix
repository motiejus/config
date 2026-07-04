{
  lib,
  stdenvNoCC,
  fetchgit,
  compressDrvWeb,
  runCommand,
  pkgs-unstable,
}:

let
  # Static assets get precompressed .gz/.br/.zst siblings (the wasm is the
  # big one); caddy serves them via file_server's `precompressed`.
  www = compressDrvWeb (stdenvNoCC.mkDerivation {
    pname = "stagit-ng";
    version = "0-unstable-2026-07-04";

    src = fetchgit {
      url = "https://git.jakstys.lt/motiejus/stagit-ng.git";
      rev = "5a5f732a959adb98b7b3412b7ad27af32edab30e";
      hash = "sha256-3ZDTmjL0N1pkmw90gHetijwOnCCgd5NWrrWjegRYUvU=";
    };

    # TODO: nixos-25.11 only ships zig 0.15; stagit-ng needs 0.16, so pull it
    # from pkgs-unstable. nixpkgs got zig_0_16 (the default `zig`) on
    # 2026-04-14, so once this config is on nixos-26.05+, replace this with
    # the stable `zig` and drop the pkgs-unstable dependency.
    nativeBuildInputs = [ pkgs-unstable.zig_0_16 ];

    dontConfigure = true;
    dontInstall = true;

    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build --release=fast -p $out
      runHook postBuild
    '';

    meta = {
      description = "Client-side git repository browser (wasm) over dumb HTTP";
      homepage = "https://git.jakstys.lt/#motiejus/stagit-ng.git";
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

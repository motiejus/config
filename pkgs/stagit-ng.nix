{
  lib,
  stdenvNoCC,
  fetchgit,
  pkgs-unstable,
}:

stdenvNoCC.mkDerivation {
  pname = "stagit-ng";
  version = "0-unstable-2026-07-03";

  src = fetchgit {
    url = "https://git.jakstys.lt/motiejus/stagit-ng.git";
    rev = "2b285d96bc20625481a6351115b55259bdcd10f6";
    hash = "sha256-kjvIugfGu6yuEi5yN6rABKXlWhJI5/k2edXyCl6ovho=";
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
}

{
  lib,
  zigpkgs,
  stdenvNoCC,
  fetchgit,
  compressDrvWebEtag,
}:

# The wasm is the big one to precompress.
compressDrvWebEtag
  (stdenvNoCC.mkDerivation {
    pname = "stagit-ng";
    version = "0-unstable-2026-11-19";

    src = fetchgit {
      # TODO: flatten to https://git.jakstys.lt/stagit-ng.git once the flat
      # namespace is deployed — this owner-qualified form then only works
      # via the temporary @oldclone redirect and blocks its removal.
      url = "https://git.jakstys.lt/motiejus/stagit-ng.git";
      rev = "fa0bf073a452dd17c0ca2d62cb403869dae53dec92068d8e335d066b6e7a7e95";
      # The repo is in sha256 object format; fetchgit's `git init` defaults
      # to sha1 and then rejects the sha256 pack ("pack is corrupted").
      # nixpkgs has no object-format knob, so set git's via preFetch.
      preFetch = "export GIT_DEFAULT_HASH=sha256";
      hash = "sha256-EByHTOwLYr6fLWsMaM1Oj4H8c7674RGfMZIpqUAIOxw=";
    };

    nativeBuildInputs = [ zigpkgs."0.17.1" ];

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
  })
  {
    extraFormats = [ "wasm" ];
  }

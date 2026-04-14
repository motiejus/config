{
  lib,
  stdenv,
  fetchurl,
  undmg,
}:

stdenv.mkDerivation rec {
  pname = "xscreensaver-mac";
  version = "6.15";

  src = fetchurl {
    url = "https://www.jwz.org/xscreensaver/xscreensaver-${version}.dmg";
    hash = "sha256-wEtIKXB/I6FSwBu7P+FlK1ve/FL5dgWiKOVRv81U2do=";
  };

  nativeBuildInputs = [ undmg ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Library/Screen Savers"
    cp -R "Screen Savers/"*.saver "$out/Library/Screen Savers/"
    runHook postInstall
  '';

  meta = {
    description = "XScreenSaver native macOS screen savers";
    homepage = "https://www.jwz.org/xscreensaver/";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
}

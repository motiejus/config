{
  lib,
  stdenv,
  fetchurl,
  undmg,
}:

stdenv.mkDerivation rec {
  pname = "xscreensaver-mac";
  version = "6.16";

  src = fetchurl {
    url = "https://www.jwz.org/xscreensaver/xscreensaver-${version}.dmg";
    hash = "sha256-fxH2/gcF5T2PBRZyUN8G9IXBSpa6dLud8gzmGaZ9i8Y=";
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

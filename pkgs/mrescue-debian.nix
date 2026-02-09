{
  pkgs,
  stdenv,
  fetchurl,
}:
{
  flavor,
  version,
  hash,
}:

stdenv.mkDerivation rec {
  pname = "mrescue-debian-${flavor}";
  inherit version;

  src = fetchurl {
    urls = [
      "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-${version}-amd64-${flavor}.iso"
      "https://dl.jakstys.lt/boot/debian-live-${version}-amd64-${flavor}.iso"
    ];
    inherit hash;
  };

  nativeBuildInputs = with pkgs; [
    p7zip
  ];

  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    mkdir debian-live
    7z x -odebian-live $src
    runHook postUnpack
  '';

  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r debian-live/* $out/

    runHook postInstall
  '';
}

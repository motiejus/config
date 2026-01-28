{
  pkgs,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "mrescue-debian-xfce";
  version = "13.3.0";

  src = fetchurl {
    url = "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-${version}-amd64-xfce.iso";
    hash = "sha256-xvHLR2gOOdsTIu7FrOZdxgfG6keqniEhhf9ywJmtNXQ=";
  };

  nativeBuildInputs = with pkgs; [
    p7zip
  ];

  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    mkdir debian-live
    7z x -odebian-live $src >/dev/null
    runHook postUnpack
  '';

  buildPhase = ''
    runHook preBuild
    # No build phase needed - files are extracted directly
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    install -Dm644 debian-live/live/vmlinuz $out/kernel
    install -Dm644 debian-live/live/initrd.img $out/initrd
    install -Dm644 debian-live/live/filesystem.squashfs $out/filesystem.squashfs

    runHook postInstall
  '';
}

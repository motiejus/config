{
  pkgs,
  stdenv,
  fetchurl,
}:

let
  # NixOS netboot files from nix-community/nixos-images
  # Source: https://github.com/nix-community/nixos-images/releases
  version = "25.11";

  kernel = fetchurl {
    urls = [
      "https://dl.jakstys.lt/boot/nixos-${version}-bzImage-x86_64-linux"
      "https://github.com/nix-community/nixos-images/releases/download/nixos-${version}/bzImage-x86_64-linux"
    ];
    hash = "sha256-ClUTxNU8YQfA8yo0vKx32fxl5Q3atXDXvGyIJP2OTpU=";
  };

  initrd =
    (fetchurl {
      urls = [
        "https://dl.jakstys.lt/boot/nixos-${version}-initrd-x86_64-linux"
        "https://github.com/nix-community/nixos-images/releases/download/nixos-${version}/initrd-x86_64-linux"
      ];
      hash = "sha256-0nLNJVrjxIKQCTPB3iz4N3j6OyQEJ2G0JTluhHOTpPU=";
    }).overrideAttrs
      (_: {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      });
in
stdenv.mkDerivation rec {
  pname = "mrescue-nixos";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    install -Dm644 ${kernel} $out/kernel
    install -Dm644 ${initrd} $out/initrd

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "NixOS minimal netboot files for rescue purposes";
    homepage = "https://github.com/nix-community/nixos-images";
    platforms = platforms.linux;
  };
}

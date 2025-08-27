{
  stdenv,
  fetchurl,
}:

let
  version = "0.71.0";
  sources = {
    x86_64-linux = {
      url = "https://storage.googleapis.com/chronosphere-release/${version}/chronoctl-linux-amd64";
      # nix store prefetch-file --hash-type sha256 https://storage.googleapis.com/chronosphere-release/0.71.0/chronoctl-linux-amd64
      hash = "sha256-SE7wuSRh3lwx7IBzqMsV3hy4DeHLfbs60uHhhIsLZMs=";
    };

    aarch64-linux = {
      url = "https://storage.googleapis.com/chronosphere-release/${version}/chronoctl-linux-arm64";
      # Replace with the real hash (SRI). For a quick prefetch:
      # nix store prefetch-file --hash-type sha256 https://storage.googleapis.com/chronosphere-release/0.71.0/chronoctl-linux-arm64
      hash = "sha256-iM9fLvpRdpvnxN+Rto1zh5BhwwEkLSuhPzODYd2TtJo=";
    };
  };

  srcInfo =
    sources.${stdenv.hostPlatform.system}
      or (throw "chronoctl: unsupported system ${stdenv.hostPlatform.system}");
in

stdenv.mkDerivation {
  pname = "chronoctl";
  inherit version;

  src = fetchurl {
    inherit (srcInfo) url hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/chronoctl"
    runHook postInstall
  '';
}

{
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  zlib,
  elfutils,
  dmidecode,
  jq,
  gcc-unwrapped,
}:
let
  sentinelOnePackage = "SentinelAgent_linux_x86_64_v25_2_2_14.deb";
in
stdenv.mkDerivation {
  pname = "sentinelone";
  version = "25.2.2.14";

  src = fetchurl {
    url = "http://hdd.jakstys.lt/Motiejaus/${sentinelOnePackage}";
    hash = "sha256-ZWtuJ/ua2roIz2I/4CicnVXlc1Sj5w/r412pS5KfmOA=";
  };

  unpackPhase = ''
    runHook preUnpack

    dpkg-deb -x $src .

    runHook postUnpack
  '';

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    zlib
    elfutils
    dmidecode
    jq
    gcc-unwrapped
  ];

  installPhase = ''
    mkdir -p $out/opt/
    mkdir -p $out/cfg/
    mkdir -p $out/bin/

    cp -r opt/* $out/opt

    ln -s $out/opt/sentinelone/bin/sentinelctl $out/bin/sentinelctl
    ln -s $out/opt/sentinelone/bin/sentinelone-agent $out/bin/sentinelone-agent
    ln -s $out/opt/sentinelone/bin/sentinelone-watchdog $out/bin/sentinelone-watchdog
    ln -s $out/opt/sentinelone/lib $out/lib
  '';

  preFixup = ''
    patchelf --replace-needed libelf.so.0 libelf.so $out/opt/sentinelone/lib/libbpf.so
  '';
}

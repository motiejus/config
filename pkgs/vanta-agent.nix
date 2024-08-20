{
  lib,
  stdenv,
  fetchurl,
  dpkg,
}:
let
  version = "2.9.0";
in
stdenv.mkDerivation {
  pname = "vanta-agent";
  inherit version;
  src = fetchurl {
    url = "https://vanta-agent-repo.s3.amazonaws.com/targets/versions/${version}/vanta-amd64.deb";
    hash = "sha256-oTiILQNXcO3rPmXdLhueQw+h2psqMUcw+UmXaU70UYs=";
  };

  nativeBuildInputs = [ dpkg ];

  unpackPhase = ''
    runHook preUnpack

    dpkg-deb -x $src .

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r usr $out/
    cp -r var $out/

    runHook postInstall
  '';

  meta = {
    description = "Vanta Agent";
    homepage = "https://vanta.com";
    maintainers = with lib.maintainers; [ matdibu ];
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

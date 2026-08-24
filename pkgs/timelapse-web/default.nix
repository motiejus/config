{
  lib,
  stdenvNoCC,
  fetchzip,
  makeWrapper,
  bash,
  coreutils,
  ffmpeg-headless,
  gawk,
  shellcheck,
  nodejs,
  chromium,
  util-linux,
}:
let
  hlsJs = fetchzip {
    url = "https://registry.npmjs.org/hls.js/-/hls.js-1.7.1.tgz";
    hash = "sha256-24kZ6RA26416zJuqKlFgo5qQrhg9s4mpIipN0EL/bKk=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "timelapse-web";
  version = "1";
  src = ./.;

  nativeBuildInputs = [
    makeWrapper
    shellcheck
    nodejs
    chromium
    ffmpeg-headless
  ];

  dontConfigure = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 publish "$out/libexec/timelapse-web/publish"
    install -Dm644 site/index.html "$out/libexec/timelapse-web/site/index.html"
    install -Dm644 site/app.js "$out/libexec/timelapse-web/site/app.js"
    install -Dm644 site/app.css "$out/libexec/timelapse-web/site/app.css"
    install -Dm644 ${hlsJs}/dist/hls.min.js "$out/libexec/timelapse-web/vendor/hls.min.js"
    install -Dm644 ${hlsJs}/LICENSE "$out/libexec/timelapse-web/vendor/LICENSE.hls.js"

    makeWrapper ${bash}/bin/bash "$out/bin/timelapse-web" \
      --add-flags "$out/libexec/timelapse-web/publish" \
      --set TIMELAPSE_MEM_LIMITED 1 \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          ffmpeg-headless
          gawk
          util-linux
        ]
      }

    runHook postInstall
  '';

  meta.mainProgram = "timelapse-web";
}

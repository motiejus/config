{
  lib,
  stdenvNoCC,
  fetchzip,
  compressDrvWeb,
  runCommand,
  makeWrapper,
  bash,
  coreutils,
  ffmpeg-headless,
  gawk,
  shellcheck,
  util-linux,
}:
let
  hlsJs = fetchzip {
    url = "https://registry.npmjs.org/hls.js/-/hls.js-1.7.1.tgz";
    hash = "sha256-24kZ6RA26416zJuqKlFgo5qQrhg9s4mpIipN0EL/bKk=";
  };
  rawSite = runCommand "timelapse-web-site" { } ''
    install -Dm644 ${./site/index.html} $out/index.html
    install -Dm644 ${./site/app.js} $out/app.js
    install -Dm644 ${./site/app.css} $out/app.css
    install -Dm644 ${hlsJs}/dist/hls.min.js $out/vendor/hls.min.js
    install -Dm644 ${hlsJs}/LICENSE $out/vendor/LICENSE.hls.js
  '';
  compressedSite = compressDrvWeb rawSite { };
  site = runCommand "timelapse-web-site-etag" { } ''
    cp -rL --no-preserve=mode ${compressedSite} $out
    find $out -type f ! -name '*.etag' | while read -r f; do
      h=$(sha256sum "$f")
      printf '"%s"' "''${h:0:32}" > "$f.etag"
    done
    for f in index.html app.js app.css vendor/hls.min.js vendor/LICENSE.hls.js; do
      test -s "$out/$f"
      test -s "$out/$f.etag"
    done
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "timelapse-web";
  version = "1";
  src = ./.;

  nativeBuildInputs = [
    makeWrapper
    shellcheck
  ];

  dontConfigure = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${bash}/bin/bash -n publish
    ${shellcheck}/bin/shellcheck -s bash publish

    mkdir -p "$TMPDIR/videos"
    TIMELAPSE_MEM_LIMITED=1 \
      TIMELAPSE_ARCHIVE_ROOT="$TMPDIR/archive" \
      PATH=${
        lib.makeBinPath [
          coreutils
          gawk
          util-linux
        ]
      } \
      ${bash}/bin/bash publish "$TMPDIR/videos"
    actual=$(ls -A1 "$TMPDIR/archive" | sort)
    expected=$(printf '%s\n' .publish.lock catalog.json ranges)
    test "$actual" = "$expected"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 publish "$out/libexec/timelapse-web/publish"
    install -Dm644 Caddyfile.snippet "$out/share/timelapse-web/Caddyfile.snippet"

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

  passthru = {
    inherit site;
    caddyfile = "${finalAttrs.finalPackage}/share/timelapse-web/Caddyfile.snippet";
  };

  meta.mainProgram = "timelapse-web";
})

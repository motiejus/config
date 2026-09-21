{
  lib,
  stdenvNoCC,
  apple-sdk,
  zigpkgs,
  google-cloud-sdk,
}:

stdenvNoCC.mkDerivation {
  pname = "sessionbar";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ zigpkgs."0.16.0" ];
  # Only the framework .tbd stubs are used; the app talks to the Objective-C
  # runtime through its C API, so no SDK headers are needed. The setup hook
  # exports SDKROOT, which build.zig reads.
  buildInputs = [ apple-sdk ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export XDG_CACHE_HOME="$TMPDIR/zig-cache"
    zig build -Doptimize=ReleaseSmall \
      -Dreauth="$out/bin/gcloud-force-reauth" \
      -Dgcloud=${lib.getExe google-cloud-sdk}
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm555 -t $out/bin zig-out/bin/sessionbar zig-out/bin/gcloud-force-reauth
    runHook postInstall
  '';

  meta = {
    description = "Menu bar countdown to the next gcloud reauth";
    mainProgram = "sessionbar";
    platforms = lib.platforms.darwin;
  };
}

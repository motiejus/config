{
  lib,
  stdenvNoCC,
  apple-sdk,
  zig_0_16,
  google-cloud-sdk,
}:

let
  # -Dsdk is explicit so the build never depends on SDKROOT leaking in; the
  # SDK supplies only framework .tbd stubs, as the app drives the Objective-C
  # runtime through its C API and needs no headers.
  commonFlags = [
    "-Dcpu=baseline"
    "--release=small"
    "-Dsdk=${apple-sdk.sdkroot}"
    # Deliberately the raw gcloud, not pkgs/gcloud-wrapped: the wrapper only
    # intercepts `config config-helper --format json`, so it would change
    # nothing here while dragging its Go build into the closure.
    "-Dgcloud=${lib.getExe google-cloud-sdk}"
    "-Dokta-host=paloaltonetworks.okta.com"
    "-Dokta-app=exk1tyqe5nFkbXBBj1t7"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "sessionbar";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ zig_0_16 ];
  buildInputs = [ apple-sdk ];

  # The hook would otherwise append its own --release=safe last, winning.
  dontSetZigDefaultFlags = true;
  zigBuildFlags = commonFlags;
  # zigCheckPhase does not inherit zigBuildFlags; same flags keep the build,
  # check and install phases on one options hash.
  zigCheckFlags = commonFlags;
  doCheck = true;

  meta = {
    description = "Menu bar countdown to the next gcloud reauth";
    mainProgram = "sessionbar";
    license = lib.licenses.mit0; # repo LICENSE is MIT No Attribution
    platforms = lib.platforms.darwin;
  };
}

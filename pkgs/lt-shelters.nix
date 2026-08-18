{
  writeShellApplication,
  fetchgit,
  curl,
  jq,
  gawk,
  coreutils,
}:

let
  src = fetchgit {
    url = "https://git.jakstys.lt/lt-shelters.git";
    rev = "6d68c6c725f3c73cb16d7e4eacbc1860c9f806194d7de4f8c94af81a42a6bc13";
    # The repo is in sha256 object format; fetchgit's `git init` defaults
    # to sha1 and then rejects the sha256 pack ("pack is corrupted").
    # nixpkgs has no object-format knob, so set git's via preFetch (see
    # pkgs/stagit-ng.nix for the same fix).
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-/22srhs2tvrELWznBOEFQVnh8nuJwbgNRqDW8QRfev4=";
  };
in
writeShellApplication {
  name = "refresh";
  runtimeInputs = [
    curl
    jq
    gawk
    coreutils
  ];
  text = builtins.readFile "${src}/refresh";
}

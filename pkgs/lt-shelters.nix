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
    rev = "bee531bca4fe20255e3bd358339c25e1dfdaf6f996afeab5a00d4cd770c31f11";
    # The repo is in sha256 object format; fetchgit's `git init` defaults
    # to sha1 and then rejects the sha256 pack ("pack is corrupted").
    # nixpkgs has no object-format knob, so set git's via preFetch (see
    # pkgs/stagit-ng.nix for the same fix).
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-sORAZNsXX4CaBJ2QX5DcA1qorBlrM+WPiCiE8HHmnSg=";
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

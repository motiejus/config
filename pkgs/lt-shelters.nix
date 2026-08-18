{
  buildGoModule,
  fetchgit,
}:

let
  src = fetchgit {
    url = "https://git.jakstys.lt/lt-shelters.git";
    rev = "63759a938cab30438810f702177070d34608a2d02c189e4bcd7b3a8b02a457c7";
    # The repo is in sha256 object format; fetchgit's `git init` defaults
    # to sha1 and then rejects the sha256 pack ("pack is corrupted").
    # nixpkgs has no object-format knob, so set git's via preFetch (see
    # pkgs/stagit-ng.nix for the same fix).
    preFetch = "export GIT_DEFAULT_HASH=sha256";
    hash = "sha256-2xen3SIjhJO68xhdeabxyqivvIqyKRmsWk80hkdIM/M=";
  };
in
buildGoModule {
  pname = "lt-shelters";
  version = "0-unstable";
  inherit src;
  vendorHash = null;
  subPackages = [ "cmd/refresh" ];
}

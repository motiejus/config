let
  krops = builtins.fetchGit {
    url = "https://cgit.krebsco.de/krops/";
  };
  lib = import "${krops}/lib";
  pkgs = import "${krops}/pkgs" {};

  source = lib.evalSource [
    {
      nixpkgs.symlink = "/root/.nix-defexpr/channels/nixos";
      nixos-config.file = toString ./configuration.nix;
    }
  ];

in {
  hel1a = pkgs.krops.writeDeploy "deploy-hel1a" {
    source = source;
    target = lib.mkTarget "motiejus@hel1-a.jakstys.lt" // {
      sudo = true;
    };
  };
}

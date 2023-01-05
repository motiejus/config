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

      # TODO: how to make this nix-managed?
      snaplink.file = toString ./scripts/snaplink;
      secrets.pass = {
        dir = toString ./secrets;
        name = "hel1-a";
      };
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

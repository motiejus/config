{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11-small";
    flake-utils.url = "github:numtide/flake-utils";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix.inputs.darwin.follows = "";

    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.inputs.utils.follows = "flake-utils";

  };

  nixConfig = {
    trusted-substituters = "https://cache.nixos.org/";
    trusted-public-keys = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
    extra-experimental-features = "nix-command flakes";
  };

  outputs = {
    self,
    nixpkgs,
    agenix,
    deploy-rs,
    flake-utils,
  }: let
    myData = import ./data.nix;
  in
    {
      nixosConfigurations.hel1-a = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          ./hardware-configuration.nix
          ./zfs.nix

          agenix.nixosModules.default

          #{
          #  age.secrets.zfs-passphrase.file = ./secrets/hel1-a/zfs-passphrase.age;
          #  age.secrets.borgbackup-password.file = ./secrets/hel1-a/borgbackup/password.age;
          #}
        ];
      };

      deploy.nodes.hel1-a = {
        hostname = "hel1-a.servers.jakst";
        profiles = {
          system = {
            sshUser = "motiejus";
            path =
              deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.hel1-a;
            user = "root";
          };
        };
      };

      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      devShells.default = with pkgs;
        mkShell {
          packages = [
              pkgs.rage
              pkgs.age-plugin-yubikey
              agenix.packages.${system}.agenix
              deploy-rs.packages.${system}.deploy-rs
          ];
        };

      formatter = pkgs.alejandra;
    });
}

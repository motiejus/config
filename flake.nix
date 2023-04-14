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
  };

  outputs = {
    self,
    nixpkgs,
    agenix,
    deploy-rs,
    flake-utils,
  } @ inputs: let
    myData = import ./data.nix;
  in
    {
      nixosConfigurations.hel1-a = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          ./hardware-configuration.nix
          ./zfs.nix
        ];

        specialArgs = inputs;
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
            pkgs.ssh-to-age
            pkgs.age-plugin-yubikey

            agenix.packages.${system}.agenix

            deploy-rs.packages.${system}.deploy-rs
          ];
        };

      formatter = pkgs.alejandra;
    });
}

{
  description = "motiejus/config";

  inputs = {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11-small";

      deploy-rs.url = "github:serokell/deploy-rs";
      deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
      deploy-rs.inputs.utils.follows = "flake-utils";

      flake-utils.url = "github:numtide/flake-utils";

  };

  outputs = { self, nixpkgs, deploy-rs, flake-utils }: {
    nixosConfigurations.hel1-a = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
          ./configuration.nix
          ./hardware-configuration.nix
          ./zfs.nix
      ];
    };

    deploy.nodes.example = {
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
  };
}


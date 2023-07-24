{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";

    # TODO: called with unexpected argument 'home-manager'
    #home-manager.url = "github:nix-community/home-manager/release-23.05";
    #home-manager.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    # see home-manager above
    #agenix.inputs.home-manager.follows = "home-manager";
    agenix.inputs.home-manager.follows = "";
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
      #nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      #  system = "x86_64-linux";
      #  modules = [
      #    ./hosts/vm/configuration.nix
      #    ./modules
      #  ];

      #  specialArgs = {inherit myData;} // inputs;
      #};

      nixosConfigurations.hel1-a = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/hel1-a/configuration.nix
          ./hosts/hel1-a/hardware-configuration.nix
          ./hosts/hel1-a/zfs.nix

          ./modules

          agenix.nixosModules.default

          {
            age.secrets.motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
            age.secrets.root-passwd-hash.file = ./secrets/root_passwd_hash.age;
            age.secrets.zfs-passphrase-vno1-oh2.file = ./secrets/vno1-oh2/zfs-passphrase.age;

            age.secrets.borgbackup-password.file = ./secrets/hel1-a/borgbackup/password.age;
            age.secrets.sasl-passwd.file = ./secrets/hel1-a/postfix/sasl_passwd.age;
            age.secrets.turn-static-auth-secret.file = ./secrets/hel1-a/turn/static_auth_secret.age;
            age.secrets.synapse-jakstys-signing-key.file = ./secrets/hel1-a/synapse/jakstys_lt_signing_key.age;
            age.secrets.synapse-registration-shared-secret.file = ./secrets/hel1-a/synapse/registration_shared_secret.age;
            age.secrets.synapse-macaroon-secret-key.file = ./secrets/hel1-a/synapse/macaroon_secret_key.age;
          }
        ];

        specialArgs = {inherit myData;} // inputs;
      };

      nixosConfigurations.vno1-oh2 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/vno1-oh2/configuration.nix

          ./modules

          agenix.nixosModules.default

          {
            age.secrets.motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
            age.secrets.root-passwd-hash.file = ./secrets/root_passwd_hash.age;
            age.secrets.zfs-passphrase-hel1-a.file = ./secrets/hel1-a/zfs-passphrase.age;
          }
        ];

        specialArgs = {inherit myData;} // inputs;
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

      deploy.nodes.vno1-oh2 = {
        hostname = "vno1-oh2.servers.jakst";
        profiles = {
          system = {
            sshUser = "motiejus";
            path =
              deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.vno1-oh2;
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
          LOCALE_ARCHIVE = "${glibcLocales}/lib/locale/locale-archive";
          packages = [
            pkgs.rage
            pkgs.ssh-to-age
            pkgs.age-plugin-yubikey
            pkgs.borgbackup

            agenix.packages.${system}.agenix

            deploy-rs.packages.${system}.deploy-rs
          ];
        };

      formatter = pkgs.alejandra;
    });
}

{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:nix-community/flake-compat";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nur.url = "github:nix-community/NUR";

    home-manager.url = "github:nix-community/home-manager/release-23.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        darwin.follows = "";
      };
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        utils.follows = "flake-utils";
      };
    };

    nixgl = {
      url = "github:guibou/nixGL";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    nix-index-database.url = "github:Mic92/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    gitignore.url = "github:hercules-ci/gitignore.nix";
    gitignore.inputs.nixpkgs.follows = "nixpkgs";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-stable.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        flake-utils.follows = "flake-utils";
        gitignore.follows = "gitignore";
      };
    };

    e11sync = {
      url = "git+https://git.jakstys.lt/motiejus/e11sync";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "flake-compat";
        gitignore.follows = "gitignore";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };
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
    home-manager,
    nixos-hardware,
    nix-index-database,
    pre-commit-hooks,
    nur,
    nixgl,
    e11sync,
    ...
  } @ inputs: let
    myData = import ./data.nix;

    overlays = [
      nur.overlay
      nixgl.overlay
      e11sync.overlays.default

      (_self: super: {deploy-rs-pkg = super.deploy-rs;})
      deploy-rs.overlay
      (_self: super: {
        deploy-rs = {
          deploy-rs = super.deploy-rs-pkg;
          inherit (super.deploy-rs) lib;
        };
      })
    ];
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

      nixosConfigurations = {
        vno1-oh2 = nixpkgs.lib.nixosSystem rec {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/vno1-oh2/configuration.nix

            ./modules

            agenix.nixosModules.default
            home-manager.nixosModules.home-manager

            {
              age.secrets = {
                motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
                root-passwd-hash.file = ./secrets/root_passwd_hash.age;
                zfs-passphrase-fra1-a.file = ./secrets/fra1-a/zfs-passphrase.age;

                photoprism-admin-passwd.file = ./secrets/photoprism/admin_password.age;
                headscale-client-oidc.file = ./secrets/headscale/oidc_client_secret2.age;
                sasl-passwd.file = ./secrets/postfix_sasl_passwd.age;
                borgbackup-password.file = ./secrets/vno1-oh2/borgbackup/password.age;
                grafana-oidc.file = ./secrets/grafana.jakstys.lt/oidc.age;
                letsencrypt-account-key.file = ./secrets/letsencrypt/account.key.age;
                vaultwarden-secrets-env.file = ./secrets/vaultwarden/secrets.env.age;

                synapse-jakstys-signing-key.file = ./secrets/synapse/jakstys_lt_signing_key.age;
                synapse-registration-shared-secret.file = ./secrets/synapse/registration_shared_secret.age;
                synapse-macaroon-secret-key.file = ./secrets/synapse/macaroon_secret_key.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        fwminex = nixpkgs.lib.nixosSystem rec {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/fwminex/configuration.nix

            ./modules
            ./modules/profiles/desktop

            nur.nixosModules.nur
            agenix.nixosModules.default
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.framework-12th-gen-intel
            nix-index-database.nixosModules.nix-index

            {
              age.secrets = {
                motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
                root-passwd-hash.file = ./secrets/root_passwd_hash.age;
                sasl-passwd.file = ./secrets/postfix_sasl_passwd.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        vno3-rp3b = nixpkgs.lib.nixosSystem rec {
          system = "aarch64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/vno3-rp3b/configuration.nix

            ./modules

            agenix.nixosModules.default
            home-manager.nixosModules.home-manager

            {
              age.secrets = {
                motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
                root-passwd-hash.file = ./secrets/root_passwd_hash.age;
                sasl-passwd.file = ./secrets/postfix_sasl_passwd.age;

                datapool-passphrase.file = ./secrets/vno3-rp3b/datapool-passphrase.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        fra1-a = nixpkgs.lib.nixosSystem rec {
          system = "aarch64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            e11sync.nixosModules.e11sync
            agenix.nixosModules.default
            home-manager.nixosModules.home-manager

            ./hosts/fra1-a/configuration.nix
            ./modules

            {
              age.secrets = {
                zfs-passphrase-vno1-oh2.file = ./secrets/vno1-oh2/zfs-passphrase.age;
                borgbackup-password.file = ./secrets/fra1-a/borgbackup-password.age;
                e11sync-secret-key.file = ./secrets/e11sync/secret-key.age;
                motiejus-passwd-hash.file = ./secrets/motiejus_passwd_hash.age;
                root-passwd-hash.file = ./secrets/root_passwd_hash.age;
                sasl-passwd.file = ./secrets/postfix_sasl_passwd.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };
      };

      deploy.nodes = {
        vno1-oh2 = {
          hostname = myData.hosts."vno1-oh2.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.vno1-oh2.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno1-oh2;
              user = "root";
            };
          };
        };

        fwminex = {
          hostname = myData.hosts."fwminex.motiejus.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.fwminex.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fwminex;
              user = "root";
            };
          };
        };

        vno3-rp3b = {
          hostname = myData.hosts."vno3-rp3b.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.vno3-rp3b.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno3-rp3b;
              user = "root";
            };
          };
        };

        fra1-a = {
          hostname = myData.hosts."fra1-a.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.fra1-a.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fra1-a;
              user = "root";
            };
          };
        };
      };

      checks =
        builtins.mapAttrs (
          system: deployLib:
            deployLib.deployChecks self.deploy
            #// self.homeConfigurations.${system}.motiejusja.activationPackage
            // {
              pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
                src = ./.;
                hooks = {
                  alejandra.enable = true;
                  deadnix.enable = true;
                  statix.enable = true;
                };
              };
            }
        )
        deploy-rs.lib;
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system overlays;};
    in {
      homeConfigurations.motiejusja = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          shared/home
        ];
        extraSpecialArgs = {
          stateVersion = "23.05";
          email = "motiejusja@wix.com";
          fullDesktop = true;
          hmOnly = true;
        };
      };

      devShells.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.rage
          pkgs.ssh-to-age
          pkgs.age-plugin-yubikey
          pkgs.deploy-rs.deploy-rs

          agenix.packages.${system}.agenix
        ];
        inherit (inputs.self.checks.${system}.pre-commit-check) shellHook;
      };

      formatter = pkgs.alejandra;
    });
}

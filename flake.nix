{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:nix-community/flake-compat";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nur.url = "github:nix-community/NUR";

    home-manager.url = "github:nix-community/home-manager/release-24.05";
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
        deploy-rs-pkg = null;
      })
      (_: super: {
        inherit (super.callPackage ./pkgs/compress-drv.nix {}) compressDrvWeb;

        tmuxbash = super.callPackage ./pkgs/tmuxbash.nix {};
        btrfs-auto-snapshot = super.callPackage ./pkgs/btrfs-auto-snapshot.nix {};
        nicer = super.callPackage ./pkgs/nicer.nix {};

        crossArm64 = import nixpkgs {
          system = "x86_64-linux";
          hostPlatform.config = "aarch64-linux";
          buildPlatform.config = "x86_64-linux";
        };
      })
    ];

    mkVM = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          {nixpkgs.overlays = overlays;}
          ./hosts/vm/configuration.nix

          ./modules
          ./modules/profiles/desktop

          home-manager.nixosModules.home-manager
        ];
        specialArgs = {inherit myData;} // inputs;
      };
  in
    {
      nixosConfigurations = {
        vm-x86_64 = mkVM "x86_64-linux";
        vm-aarch64 = mkVM "aarch64-linux";

        op5p = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/op5p/configuration.nix
            home-manager.nixosModules.home-manager
          ];
          specialArgs = {inherit myData;} // inputs;
        };

        vno1-op5p = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/vno1-op5p/configuration.nix
            home-manager.nixosModules.home-manager

            agenix.nixosModules.default
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

        mtworx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = overlays;}
            ./hosts/mtworx/configuration.nix
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.lenovo-thinkpad-x1-11th-gen
            nix-index-database.nixosModules.nix-index

            agenix.nixosModules.default
            {
              age.secrets = {
                motiejus-work-passwd-hash.file = ./secrets/motiejus_work_passwd_hash.age;
                root-work-passwd-hash.file = ./secrets/root_work_passwd_hash.age;
                #sasl-passwd.file = ./secrets/postfix_sasl_passwd.age;

                syncthing-key.file = ./secrets/mtworx/syncthing/key.pem.age;
                syncthing-cert.file = ./secrets/mtworx/syncthing/cert.pem.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        vno1-oh2 = nixpkgs.lib.nixosSystem {
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

                syncthing-key.file = ./secrets/vno1-oh2/syncthing/key.pem.age;
                syncthing-cert.file = ./secrets/vno1-oh2/syncthing/cert.pem.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        fwminex = nixpkgs.lib.nixosSystem {
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
                syncthing-key.file = ./secrets/fwminex/syncthing/key.pem.age;
                syncthing-cert.file = ./secrets/fwminex/syncthing/cert.pem.age;
              };
            }
          ];

          specialArgs = {inherit myData;} // inputs;
        };

        vno3-rp3b = nixpkgs.lib.nixosSystem {
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

        fra1-a = nixpkgs.lib.nixosSystem {
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

        mtworx = {
          hostname = myData.hosts."mtworx.motiejus.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.mtworx.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.mtworx;
              user = "root";
            };
          };
        };

        vno1-op5p = {
          hostname = myData.hosts."vno1-op5p.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path =
                self.nixosConfigurations.vno1-op5p.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno1-op5p;
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
            // {
              pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
                src = ./.;
                hooks = {
                  alejandra.enable = true;
                  deadnix.enable = true;
                  statix.enable = true;
                };
              };

              #compress-drv-tests = let
              #  pkgs = import nixpkgs {inherit system;};
              #in
              #  pkgs.callPackage ./pkgs/compress-drv-tests.nix {};
            }
        )
        deploy-rs.lib;
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system overlays;};
    in {
      devShells.default = pkgs.mkShellNoCC {
        GIT_AUTHOR_EMAIL = "motiejus@jakstys.lt";
        packages = [
          pkgs.nix-output-monitor
          pkgs.rage
          pkgs.age-plugin-yubikey
          pkgs.deploy-rs.deploy-rs
          agenix.packages.${system}.agenix
        ];
        inherit (self.checks.${system}.pre-commit-check) shellHook;
      };

      formatter = pkgs.alejandra;
    });
}

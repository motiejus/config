{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:nix-community/flake-compat";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nur.url = "github:nix-community/NUR";

    home-manager.url = "github:nix-community/home-manager/release-25.05";
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
      url = "github:serokell/deploy-rs/5829cec63845eb50984dc8787b0edfe81bf5b980"; # https://github.com/serokell/deploy-rs/issues/325
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        utils.follows = "flake-utils";
      };
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        flake-utils.follows = "flake-utils";
      };
    };

    kolide-launcher = {
      url = "github:/kolide/nix-agent/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database.url = "github:Mic92/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    gitignore.url = "github:hercules-ci/gitignore.nix";
    gitignore.inputs.nixpkgs.follows = "nixpkgs";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        gitignore.follows = "gitignore";
      };
    };
  };

  nixConfig = {
    trusted-substituters = "https://cache.nixos.org/";
    trusted-public-keys = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
    extra-experimental-features = "nix-command flakes";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      agenix,
      deploy-rs,
      flake-utils,
      home-manager,
      nixos-hardware,
      nix-index-database,
      pre-commit-hooks,
      nur,
      zig,
      kolide-launcher,
      ...
    }@inputs:
    let
      myData = import ./data.nix;

      baseOverlays = [
        nur.overlays.default
        zig.overlays.default

        (_self: super: { deploy-rs-pkg = super.deploy-rs; })
        #deploy-rs.overlays.default
        (_self: super: {
          deploy-rs = {
            deploy-rs = super.deploy-rs-pkg;
            inherit (super.deploy-rs) lib;
          };
          deploy-rs-pkg = null;
        })
        (_: super: {
          gamja = super.callPackage ./pkgs/gamja.nix { };
          weather = super.callPackage ./pkgs/weather { };
          nicer = super.callPackage ./pkgs/nicer.nix { };
          tmuxbash = super.callPackage ./pkgs/tmuxbash.nix { };
          vanta-agent = super.callPackage ./pkgs/vanta-agent.nix { };
          chronoctl = super.callPackage ./pkgs/chronoctl.nix { };
          gcloud-wrapped = super.callPackage ./pkgs/gcloud-wrapped { };
          go-raceless = super.callPackage ./pkgs/go-raceless { };

          pkgs-unstable = import nixpkgs-unstable {
            inherit (super) system;
            overlays = [
              (_self: super: {
                go = super.go_1_25;
                buildGoModule = super.buildGo125Module;
                buildGoPackage = super.buildGo125Package;
              })
            ];
          };
        })
      ];

    in
    {
      inherit (nixpkgs) legacyPackages;

      nixosConfigurations = {
        vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/vm/configuration.nix
            home-manager.nixosModules.home-manager
          ];
          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        mtworx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/mtworx/configuration.nix
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.lenovo-thinkpad-x1-11th-gen
            nix-index-database.nixosModules.nix-index
            agenix.nixosModules.default
            kolide-launcher.nixosModules.kolide-launcher
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        fwminex = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/fwminex/configuration.nix
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.framework-12th-gen-intel

            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        vno3-nk = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/vno3-nk/configuration.nix
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        vno1-gdrx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/vno1-gdrx/configuration.nix
            home-manager.nixosModules.home-manager
            nix-index-database.nixosModules.nix-index

            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        fra1-c = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            agenix.nixosModules.default
            home-manager.nixosModules.home-manager
            ./hosts/fra1-c/configuration.nix
            ./modules
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

      };

      deploy.nodes = {
        fwminex = {
          hostname = "fwminex.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.fwminex.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fwminex;
              user = "root";
            };
          };
        };

        mtworx = {
          hostname = "mtworx.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.mtworx.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.mtworx;
              user = "root";
            };
          };
        };

        vno1-gdrx = {
          hostname = "vno1-gdrx.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.vno1-gdrx.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno1-gdrx;
              user = "root";
            };
          };
        };

        vno3-nk = {
          hostname = "vno3-nk.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.vno3-nk.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno3-nk;
              user = "root";
            };
          };
        };

        fra1-c = {
          hostname = "fra1-c.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.fra1-c.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fra1-c;
              user = "root";
            };
          };
        };

      };
      checks = builtins.mapAttrs (
        system: deployLib:
        deployLib.deployChecks self.deploy
        // {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              statix.enable = true;
              deadnix.enable = true;
              nixfmt-rfc-style.enable = true;
            };
          };
        }
      ) deploy-rs.lib;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = baseOverlays;
        };
      in
      {
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

        formatter = pkgs.nixfmt-rfc-style;
      }
    )

    // (
      let
        pkgs = import nixpkgs {
          overlays = baseOverlays;
          system = "x86_64-linux";
        };
      in
      {
        packages.x86_64-linux = {
          inherit (pkgs) weather gamja chronoctl;
        };
      }
    );

}

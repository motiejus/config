{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      nixgl,
      ...
    }@inputs:
    let
      myData = import ./data.nix;

      overlays = [
        nur.overlay
        nixgl.overlay

        (_self: super: { deploy-rs-pkg = super.deploy-rs; })
        deploy-rs.overlay
        (_self: super: {
          deploy-rs = {
            deploy-rs = super.deploy-rs-pkg;
            inherit (super.deploy-rs) lib;
          };
          deploy-rs-pkg = null;
        })
        (_: super: {
          nicer = super.callPackage ./pkgs/nicer.nix { };
          imapsync = super.callPackage ./pkgs/imapsync.nix { };
          tmuxbash = super.callPackage ./pkgs/tmuxbash.nix { };
          vanta-agent = super.callPackage ./pkgs/vanta-agent.nix { };

          pkgs-unstable = import nixpkgs-unstable {
            inherit (super) system;
            overlays = [
              (_self: super: {
                go = super.go_1_23;
                buildGoModule = super.buildGo123Module;
                buildGoPackage = super.buildGo123Package;
              })
            ];
          };
        })
      ];

      mkVM =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = overlays; }
            ./hosts/vm/configuration.nix

            ./modules
            ./modules/profiles/desktop

            home-manager.nixosModules.home-manager
          ];
          specialArgs = {
            inherit myData;
          } // inputs;
        };
    in
    {
      nixosConfigurations = {
        vm-x86_64 = mkVM "x86_64-linux";
        vm-aarch64 = mkVM "aarch64-linux";

        mtworx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = overlays; }
            ./hosts/mtworx/configuration.nix
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.lenovo-thinkpad-x1-11th-gen
            nix-index-database.nixosModules.nix-index
            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          } // inputs;
        };

        fwminex = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = overlays; }
            ./hosts/fwminex/configuration.nix
            home-manager.nixosModules.home-manager
            nixos-hardware.nixosModules.framework-12th-gen-intel

            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          } // inputs;
        };

        vno1-gdrx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = overlays; }
            ./hosts/vno1-gdrx/configuration.nix
            home-manager.nixosModules.home-manager
            nix-index-database.nixosModules.nix-index

            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          } // inputs;
        };

        vno3-rp3b = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            { nixpkgs.overlays = overlays; }
            ./hosts/vno3-rp3b/configuration.nix
            ./modules
            agenix.nixosModules.default
            home-manager.nixosModules.home-manager
          ];

          specialArgs = {
            inherit myData;
          } // inputs;
        };

        fra1-b = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            { nixpkgs.overlays = overlays; }
            agenix.nixosModules.default
            home-manager.nixosModules.home-manager
            ./hosts/fra1-b/configuration.nix
            ./modules
          ];

          specialArgs = {
            inherit myData;
          } // inputs;
        };

      };

      deploy.nodes = {
        fwminex = {
          hostname = myData.hosts."fwminex.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.fwminex.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fwminex;
              user = "root";
            };
          };
        };

        mtworx = {
          hostname = myData.hosts."mtworx.motiejus.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.mtworx.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.mtworx;
              user = "root";
            };
          };
        };

        vno1-gdrx = {
          hostname = myData.hosts."vno1-gdrx.motiejus.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.vno1-gdrx.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno1-gdrx;
              user = "root";
            };
          };
        };

        vno3-rp3b = {
          hostname = myData.hosts."vno3-rp3b.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.vno3-rp3b.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.vno3-rp3b;
              user = "root";
            };
          };
        };

        fra1-b = {
          hostname = myData.hosts."fra1-b.servers.jakst".jakstIP;
          profiles = {
            system = {
              sshUser = "motiejus";
              path = self.nixosConfigurations.fra1-b.pkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.fra1-b;
              user = "root";
            };
          };
        };
      };
      checks = builtins.mapAttrs (
        system: deployLib:
        let
          pkgs = import nixpkgs { inherit system overlays; };
        in
        deployLib.deployChecks self.deploy
        // {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt = {
                enable = true;
                package = pkgs.nixfmt-rfc-style;
              };
              deadnix.enable = true;
              statix.enable = true;
            };
          };
        }
      ) deploy-rs.lib;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system overlays; };
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

    // {
      packages.x86_64-linux.vanta-agent =
        let
          pkgs = import nixpkgs {
            inherit overlays;
            system = "x86_64-linux";
          };
        in
        pkgs.vanta-agent;
    };

}

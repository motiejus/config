{
  description = "motiejus/config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:nix-community/flake-compat";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nur.url = "github:nix-community/NUR";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        darwin.follows = "nix-darwin";
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
      };
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
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
      nur,
      zig,
      nix-darwin,
      ...
    }@inputs:
    let
      myData = import ./data.nix;

      baseOverlays = [
        nur.overlays.default
        zig.overlays.default

        (
          _: super:
          rec {
            gamja = super.callPackage ./pkgs/gamja.nix { };
            weather = super.callPackage ./pkgs/weather { };
            tmuxbash = super.callPackage ./pkgs/tmuxbash.nix { };
            gcloud-wrapped = super.callPackage ./pkgs/gcloud-wrapped { };
          }
          // super.lib.optionalAttrs super.stdenv.isDarwin {
            # fish gets SIGKILL in nix sandbox on darwin, breaking direnv tests
            direnv = super.direnv.overrideAttrs { doCheck = false; };
            xscreensaver-mac = super.callPackage ./pkgs/xscreensaver-mac.nix { };
          }
          // super.lib.optionalAttrs super.stdenv.isLinux rec {
            stagit-ng = super.callPackage ./pkgs/stagit-ng.nix { };
            nicer = super.callPackage ./pkgs/nicer.nix { };
            inherit (super.callPackage ./pkgs/agent-sandboxes.nix { }) claudes codexs;
            chronoctl = super.callPackage ./pkgs/chronoctl.nix { };
            mrescue-alpine = super.callPackage ./pkgs/mrescue-alpine.nix { };

            mkDebianLive = super.callPackage ./pkgs/mrescue-debian.nix { };
            mrescue-debian-xfce = mkDebianLive {
              flavor = "xfce";
              version = "13.3.0";
              hash = "sha256-xvHLR2gOOdsTIu7FrOZdxgfG6keqniEhhf9ywJmtNXQ=";
            };

            # NixOS netboot rescue image
            # Note: Update URL and hash manually from https://nixos.org/download
            mrescue-nixos = super.callPackage ./pkgs/mrescue-nixos.nix { };
          }
          // {
            pkgs-unstable = import nixpkgs-unstable {
              inherit (super.stdenv.hostPlatform) system;
              config.allowUnfree = true;
              overlays = [
                (_self: super: {
                  go = super.go_1_26;
                  buildGoModule = super.buildGo126Module;
                  buildGoPackage = super.buildGo126Package;
                })
              ];
            };
          }
        )
      ];

    in
    {
      #inherit (nixpkgs) legacyPackages;

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
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

        vno2-desk2 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/vno2-desk2/configuration.nix
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
          ];

          specialArgs = {
            inherit myData;
          }
          // inputs;
        };

      };

      darwinConfigurations = {
        macworx = nix-darwin.lib.darwinSystem {
          modules = [
            { nixpkgs.overlays = baseOverlays; }
            ./hosts/macworx/configuration.nix
            home-manager.darwinModules.home-manager
            agenix.darwinModules.default
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
              path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.fwminex;
              user = "root";
            };
          };
        };

        vno1-gdrx = {
          hostname = "vno1-gdrx.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.vno1-gdrx;
              user = "root";
            };
          };
        };

        vno3-nk = {
          hostname = "vno3-nk.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.vno3-nk;
              user = "root";
            };
          };
        };

        fra1-c = {
          hostname = "fra1-c.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.fra1-c;
              user = "root";
            };
          };
        };

        vno2-desk2 = {
          hostname = "vno2-desk2.jakst.vpn";
          profiles = {
            system = {
              sshUser = "motiejus";
              path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.vno2-desk2;
              user = "root";
            };
          };
        };

      };
      checks = builtins.mapAttrs (
        system: deployLib:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        deployLib.deployChecks self.deploy
        // {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            # pre-commit's nativeCheckInputs pull in dotnet-sdk, go, cargo etc.;
            # pytestCheckHook leaks in via `identify` propagatedBuildInputs
            package = pkgs.pre-commit.overridePythonAttrs {
              doCheck = false;
              doInstallCheck = false;
              dontUsePytestCheck = true;
              nativeCheckInputs = [ ];
              preCheck = "";
              pytestFlags = [ ];
              disabledTests = [ ];
            };
            hooks = {
              statix.enable = true;
              deadnix.enable = true;
              nixfmt.enable = true;
            };
          };
        }
      ) deploy-rs.lib;
    }
    // flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
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
            agenix.packages.${system}.agenix
          ]
          ++ [
            pkgs.deploy-rs
          ];
          shellHook = (self.checks.${system}.pre-commit-check or { }).shellHook or "";
        };

        formatter = pkgs.nixfmt;
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
          inherit (pkgs)
            weather
            gamja
            chronoctl
            mrescue-alpine
            mrescue-debian-xfce
            mrescue-nixos
            ;
        };
      }
    );

}

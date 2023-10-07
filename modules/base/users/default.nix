{
  config,
  lib,
  myData,
  ...
}: let
  cfg = config.mj.base.users;
in {
  options.mj.base.users = with lib.types; {
    devEnvironment = lib.mkOption {
      type = bool;
      default = false;
    };

    passwd = lib.mkOption {
      type = attrsOf (submodule {
        options = {
          passwordFile = lib.mkOption {
            type = nullOr path;
            default = null;
          };
          initialPassword = lib.mkOption {
            type = nullOr str;
            default = null;
          };

          extraGroups = lib.mkOption {
            type = listOf str;
            default = [];
          };
        };
      });
    };
  };

  config = {
    users = {
      mutableUsers = false;

      users = {
        motiejus =
          {
            isNormalUser = true;
            extraGroups = ["wheel"] ++ cfg.passwd.motiejus.extraGroups;
            uid = myData.uidgid.motiejus;
            openssh.authorizedKeys.keys = [
              myData.people_pubkeys.motiejus
              "from=\"${myData.hosts."mtwork.motiejus.jakst".jakstIP}\" ${myData.people_pubkeys.motiejus_work}"
            ];
          }
          // lib.filterAttrs (
            n: v:
              (n == "passwordFile" || n == "initialPassword") && v != null
          )
          cfg.passwd.motiejus or {};

        root = assert lib.assertMsg (cfg.passwd ? root) "root password needs to be defined";
          lib.filterAttrs (_: v: v != null) cfg.passwd.root;
      };
    };

    home-manager.useGlobalPkgs = true;
    home-manager.users.motiejus = {pkgs, ...}:
      import ../../../shared/home/default.nix {
        inherit pkgs;
        inherit (config.mj) stateVersion;
        email = "motiejus@jakstys.lt";

        programs.bash = {
          enable = true;
          shellAliases = {
            "l" = "echo -n ł | xclip -selection clipboard";
            "gp" = "${pkgs.git}/bin/git remote | ${pkgs.parallel}/bin/parallel --verbose git push";
          };
        };
      };
  };
}

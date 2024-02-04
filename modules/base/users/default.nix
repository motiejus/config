{
  config,
  lib,
  myData,
  ...
}: let
  cfg = config.mj.base.users;
in {
  options.mj.base.users = with lib.types; {
    enable = lib.mkEnableOption "enable motiejus and root";
    devTools = lib.mkOption {
      type = bool;
      default = false;
    };
    passwd = lib.mkOption {
      type = attrsOf (submodule {
        options = {
          hashedPasswordFile = lib.mkOption {
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

  config = lib.mkIf cfg.enable {
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
              (n == "hashedPasswordFile" || n == "initialPassword") && v != null
          )
          cfg.passwd.motiejus or {};

        root = assert lib.assertMsg (cfg.passwd ? root) "root password needs to be defined";
          lib.filterAttrs (_: v: v != null) cfg.passwd.root;
      };
    };

    home-manager.useGlobalPkgs = true;
    home-manager.users.motiejus = {pkgs, ...}:
      import ../../../shared/home/default.nix {
        inherit lib;
        inherit pkgs;
        inherit (config.mj) stateVersion;
        inherit (cfg) devTools;
        hmOnly = false;
        email = "motiejus@jakstys.lt";
      };
  };
}

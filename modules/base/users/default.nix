{
  config,
  lib,
  myData,
  ...
}: let
  cfg = config.mj.base.users;
  props = with lib.types; {
    hashedPasswordFile = lib.mkOption {
      type = nullOr path;
      default = null;
    };
    initialPassword = lib.mkOption {
      type = nullOr str;
      default = null;
    };
    initialHashedPassword = lib.mkOption {
      type = nullOr str;
      default = null;
    };

    extraGroups = lib.mkOption {
      type = listOf str;
      default = [];
    };
  };
in {
  options.mj.base.users = with lib.types; {
    enable = lib.mkEnableOption "enable motiejus and root";
    devTools = lib.mkOption {
      type = bool;
      default = false;
    };
    email = lib.mkOption {
      type = str;
      default = "motiejus@jakstys.lt";
    };
    user = props;
    root = props;
  };

  config = lib.mkIf cfg.enable {
    users = {
      mutableUsers = false;

      users = {
        ${config.mj.username} =
          {
            isNormalUser = true;
            extraGroups = ["wheel" "dialout" "video"] ++ cfg.user.extraGroups;
            uid = myData.uidgid.motiejus;
            openssh.authorizedKeys.keys = [
              myData.people_pubkeys.motiejus
              myData.people_pubkeys.motiejus_work
            ];
          }
          // lib.filterAttrs (n: v: n != "extraGroups" && v != null) cfg.user or {};

        root = lib.filterAttrs (_: v: v != null) cfg.root;
      };
    };

    home-manager.useGlobalPkgs = true;
    home-manager.users.${config.mj.username} = {pkgs, ...}:
      import ../../../shared/home {
        inherit lib;
        inherit pkgs;
        inherit (config.mj) stateVersion username;
        inherit (cfg) devTools email;
        hmOnly = false;
      };
  };
}

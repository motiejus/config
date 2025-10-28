{
  config,
  lib,
  myData,
  ...
}:
let
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
      default = [ ];
    };
  };
in
{
  options.mj.base.users = with lib.types; {
    enable = lib.mkEnableOption "enable motiejus and root";
    devTools = lib.mkOption {
      type = bool;
      default = false;
    };
    wrapGo = lib.mkOption {
      type = bool;
      default = false;
    };
    email = lib.mkOption {
      type = nullOr str;
      default = "motiejus@jakstys.lt";
    };
    user = props;
    root = props;
  };

  config = lib.mkIf cfg.enable {
    users = {
      mutableUsers = false;

      users = {
        ${config.mj.username} = {
          isNormalUser = true;
          extraGroups = [
            "wheel"
            "dialout"
            "video"
            "audio"
          ]
          ++ cfg.user.extraGroups;
          uid = myData.uidgid.motiejus;
          openssh.authorizedKeys.keys =
            let
              fqdn = "${config.networking.hostName}.${config.networking.domain}";
            in
            lib.mkMerge [
              [
                myData.people_pubkeys.motiejus
                myData.people_pubkeys.motiejus_work
              ]

              (lib.mkIf (builtins.hasAttr fqdn myData.hosts) [
                (''from="127.0.0.1,::1" '' + myData.hosts.${fqdn}.publicKey)
              ])
            ];
        }
        // lib.filterAttrs (n: v: n != "extraGroups" && v != null) cfg.user or { };

        root = lib.filterAttrs (_: v: v != null) cfg.root;
      };
    };

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bk";
      users.${config.mj.username} =
        { pkgs, ... }:
        import ../../../shared/home {
          inherit lib;
          inherit pkgs;
          inherit (config.mj) stateVersion username;
          inherit (cfg) devTools email wrapGo;
          hmOnly = false;
        };
    };
  };
}

{ config, lib, ... }:
let
  cfg = config.mj.services.photoprism;
in
{
  options.mj.services.photoprism = with lib.types; {
    enable = lib.mkEnableOption "enable photoprism";
    uidgid = lib.mkOption { type = int; };
    paths = lib.mkOption { type = attrsOf str; };
    passwordFile = lib.mkOption { type = str; };
  };

  config = lib.mkIf cfg.enable {
    services.photoprism = {
      enable = true;
      originalsPath = "/data";
      passwordFile = cfg.passwordFile;
    };

    systemd.services.photoprism.serviceConfig = {
      ProtectHome = lib.mkForce "tmpfs";
      BindPaths = lib.mapAttrsToList (name: srcpath: "${srcpath}:/data/${name}") cfg.paths;
    };

    users = {
      groups.photoprism.gid = cfg.uidgid;
      users.photoprism = {
        group = "photoprism";
        uid = cfg.uidgid;
      };
    };
  };

}

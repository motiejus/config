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
      originalsPath = "/var/cache/photoprism/userdata";
      passwordFile = cfg.passwordFile;
    };

    systemd = {
      tmpfiles.rules = [ "d /var/cache/photoprism/userdata 0700 photoprism photoprism -" ];
      services.photoprism.serviceConfig = {
        ProtectHome = lib.mkForce "tmpfs";
        CacheDirectory = "photoprism";
        BindPaths = lib.mapAttrsToList (
          name: srcpath: "${srcpath}:/var/cache/photoprism/userdata/${name}"
        ) cfg.paths;
      };
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

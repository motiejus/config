{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mj.services.certget;
in {
  options.mj.services.certget = with lib.types; {
    enable = lib.mkEnableOption "receive acme certs from somewhere";
    uidgid = lib.mkOption {type = int;};
    sshKeys = lib.mkOption {type = listOf str;};
  };

  config = lib.mkIf cfg.enable {
    users.users.certget = {
      description = "Cert Getter";
      home = "/var/lib/certget";
      shell = "/bin/sh";
      group = "certget";
      isSystemUser = true;
      createHome = true;
      uid = cfg.uidgid;
      openssh.authorizedKeys.keys =
        map (
          k: "command=\"${pkgs.rrsync}/bin/rrsync /var/lib/certget\",restrict ${k}"
        )
        cfg.sshKeys;
    };
    users.groups.certget.gid = cfg.uidgid;
  };
}

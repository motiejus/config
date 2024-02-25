{
  config,
  lib,
  ...
}: let
  cfg = config.mj.services.remote-builder;
in {
  options.mj.services.remote-builder = with lib.types; {
    enable = lib.mkEnableOption "Enable remote builder";
    uidgid = lib.mkOption {type = int;};
    sshAllowSubnet = lib.mkOption {type = str;};
    publicKeys = lib.mkOption {type = listOf str;};
  };

  config = lib.mkIf cfg.enable {
    users.users.remote-builder = {
      description = "Remote Builder";
      home = "/var/lib/remote-builder";
      shell = "/bin/sh";
      group = "remote-builder";
      isSystemUser = true;
      createHome = true;
      uid = cfg.uidgid;
      openssh.authorizedKeys.keys =
        map (
          k: "from=\"${cfg.sshAllowSubnet}\" ${k}"
        )
        cfg.publicKeys;
    };
    users.groups.remote-builder.gid = cfg.uidgid;
    nix.settings.trusted-users = ["remote-builder"];
  };
}

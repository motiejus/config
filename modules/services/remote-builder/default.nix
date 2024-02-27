{
  config,
  lib,
  ...
}: {
  options.mj.services.remote-builder = with lib.types; {
    server = {
      enable = lib.mkEnableOption "Enable remote builder server";
      uidgid = lib.mkOption {type = int;};
      sshAllowSubnet = lib.mkOption {type = str;};
      publicKeys = lib.mkOption {type = listOf str;};
    };
    client = {
      enable = lib.mkEnableOption "Enable remote builder client";
      system = lib.mkOption {type = enum ["aarch64-linux" "x86_64-linux"];};
      hostName = lib.mkOption {type = str;};
      sshKey = lib.mkOption {type = path;};
      supportedFeatures = lib.mkOption {type = listOf str;};
    };
  };

  config = lib.mkMerge [
    (
      let
        cfg = config.mj.services.remote-builder.server;
      in
        lib.mkIf cfg.enable {
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
        }
    )
    (
      let
        cfg = config.mj.services.remote-builder.client;
      in
        lib.mkIf cfg.enable {
          nix = {
            buildMachines = [
              {
                inherit (cfg) hostName system sshKey supportedFeatures;
                protocol = "ssh-ng";
                sshUser = "remote-builder";
              }
            ];
            distributedBuilds = true;
            extraOptions = ''builders-use-substitutes = true'';
          };
        }
    )
  ];
}

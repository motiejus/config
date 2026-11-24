{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.up;
  # Published by hard link, so the tree and the tus dir share /var/www's
  # filesystem (/var/lib is another subvolume). link(2) also refuses to cross
  # bind mounts, so both sit under ONE ReadWritePaths entry; ownership keeps
  # the rest of /var/www read-only to up. /var/www is not backed up.
  root = "/var/www/up";
  tusDir = "/var/www/up-tus";
  flags = lib.escapeShellArgs [
    "-admin-listen=127.0.0.1:${toString myData.ports.up-admin}"
    "-user-listen=127.0.0.1:${toString myData.ports.up}"
    "-root=${root}"
    "-tus-dir=${tusDir}"
    "-db=/var/lib/up/up.db"
    "-base-url=https://up.jakstys.lt"
  ];
  unit = cmd: {
    User = "up";
    Group = "up";
    ExecStart = "${lib.getExe pkgs.up-jakstys-lt} ${cmd} ${flags}";
    # Dirs 0750, files 0640, group up: Caddy reads the tree as a member.
    StateDirectory = "up";
    StateDirectoryMode = "0700";
    ReadWritePaths = [ "/var/www" ];
    UMask = "0027";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    # AF_UNIX: tailscaled's LocalAPI (socket 0666; any local user may whois).
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
  };
in
{
  options.mj.services.up.enable = lib.mkEnableOption "up.jakstys.lt upload service";

  config = lib.mkIf cfg.enable {
    users = {
      users.up = {
        isSystemUser = true;
        group = "up";
        uid = myData.uidgid.up;
      };
      groups.up.gid = myData.uidgid.up;
      users.caddy.extraGroups = [ "up" ];
    };

    systemd = {
      tmpfiles.rules = [
        "d ${root} 0750 up up -"
        "d ${tusDir} 0700 up up -"
      ];

      services = {
        up = {
          description = "up.jakstys.lt uploads";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "tailscaled.service"
          ];
          serviceConfig = unit "serve" // {
            Restart = "on-failure";
          };
        };
        up-prune = {
          description = "Delete expired and abandoned up.jakstys.lt uploads";
          serviceConfig = unit "prune" // {
            Type = "oneshot";
          };
        };
      };

      timers.up-prune = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };
    };
  };
}

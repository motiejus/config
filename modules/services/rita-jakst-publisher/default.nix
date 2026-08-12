{
  config,
  lib,
  myData,
  pkgs,
  ...
}:

let
  cfg = config.mj.services.rita-jakst-publisher;
  dataDir = "/var/lib/rita.jakstys.lt";
  outputDir = "/var/www/rita.jakstys.lt/site";
in
{
  options.mj.services.rita-jakst-publisher.enable = lib.mkEnableOption "Rita's website editor";

  config = lib.mkIf cfg.enable {
    users.users.rita-jakst-publisher = {
      isSystemUser = true;
      group = "rita-jakst-publisher";
      uid = myData.uidgid.rita-jakst-publisher;
    };
    users.groups.rita-jakst-publisher.gid = myData.uidgid.rita-jakst-publisher;

    systemd.tmpfiles.rules = [
      "d /var/www/rita.jakstys.lt 0755 rita-jakst-publisher rita-jakst-publisher -"
    ];

    systemd.services.rita-jakst-publisher = {
      description = "Rita's website editor";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        graphicsmagick
        libavif
      ];
      preStart = ''
        if [[ ! -f ${outputDir}/index.html ]]; then
          ${lib.getExe pkgs.rita-jakst-publisher} publish \
            -data ${dataDir} \
            -output ${outputDir}
        fi
      '';
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${lib.getExe pkgs.rita-jakst-publisher} serve"
          "-listen 127.0.0.1:${toString myData.ports.rita-jakst-publisher}"
          "-data ${dataDir}"
          "-output ${outputDir}"
        ];
        User = "rita-jakst-publisher";
        Group = "rita-jakst-publisher";
        StateDirectory = "rita.jakstys.lt";
        StateDirectoryMode = "0750";
        Restart = "on-failure";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        NoNewPrivileges = true;
        ReadWritePaths = [ "/var/www/rita.jakstys.lt" ];
      };
    };
  };
}

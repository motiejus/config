{
  lib,
  config,
  pkgs,
  ...
}: {
  options.mj.services.wifibackup = with lib.types; {
    enable = lib.mkEnableOption "enable wifi code backups to M-Active";
    fromPath = lib.mkOption {
      type = path;
      default = "/etc/NetworkManager/system-connections";
    };
    toPath = lib.mkOption {
      type = path;
      example = "/home/motiejus/M-Active/wifi";
    };
    toUser = lib.mkOption {
      type = str;
      example = "motiejus";
    };
  };

  config = with config.mj.services.wifibackup;
    lib.mkIf enable {
      systemd.timers.wifibackup = {
        description = "wifibackup to M-Active";
        wantedBy = ["timers.target"];
        timerConfig.OnCalendar = "*-*-* 22:00:00 UTC";
      };
      systemd.services.wifibackup = {
        description = "backup ${fromPath} to ${toPath}";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          SuccessExitStatus = [0 1];
        };
        script = ''
          sed -i -E '/^(uuid|interface-name)=/d' ${fromPath}/*.nmconnection

          exec ${pkgs.unison}/bin/unison \
              -sshcmd ${pkgs.openssh}/bin/ssh \
              -sshargs "-i /etc/ssh/ssh_host_ed25519_key -o KnownHostsCommand=\"${pkgs.coreutils}/bin/cat /etc/ssh/ssh_host_ed25519_key.pub\"" \
              -batch \
              -backuploc local \
              -backup "Name *" \
              ${fromPath} \
              ssh://${toUser}@localhost/${toPath}/
        '';
      };
    };
}

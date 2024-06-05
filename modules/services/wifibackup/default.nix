{
  lib,
  config,
  pkgs,
  ...
}: let
  mergeNmConnections = pkgs.writeShellApplication {
    name = "merge-nmconnections";
    text = ''
      CURRENT1="$1"
      CURRENT2="$2"
      NEW="$3"
      NEW1="$4"
      NEW2="$5"

      sed -i -E '/^(uuid|interface-name)=/d' "$CURRENT1"
      sed -i -E '/^(uuid|interface-name)=/d' "$CURRENT2"

      if cmp "$1" "$2"; then
          mv "$CURRENT1" "$NEW"
      else
          mv "$CURRENT1" "$NEW1"
          mv "$CURRENT2" "$NEW2"
          exit 1
      fi
    '';
  };
in {
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
          ExecStart = ''
            ${pkgs.unison}/bin/unison \
                -sshcmd ${pkgs.openssh}/bin/ssh \
                -sshargs "-i /etc/ssh/ssh_host_ed25519_key" \
                -batch \
                -merge "Name *.nmconnection -> ${mergeNmConnections}/bin/merge-nmconnections CURRENT1 CURRENT2 NEW NEW1 NEW2" \
                -backuploc local \
                -backup "Name *" \
                ${fromPath} \
                ssh://${toUser}@localhost/${toPath}/
          '';
        };
      };
    };
}

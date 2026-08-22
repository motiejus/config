{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.dl-mirror;
  inherit (cfg) receiver sender;
in
{
  options.mj.services.dl-mirror = with lib.types; {
    receiver = {
      enable = lib.mkEnableOption "a restricted, browsable rsync download mirror receiver";

      domain = lib.mkOption {
        type = nullOr str;
        default = null;
        example = "dl2.example.org";
      };

      dataDir = lib.mkOption {
        type = str;
        default = "/var/www/dl";
      };

      user = lib.mkOption {
        type = str;
        default = "dl-receiver";
        description = "Unprivileged account that owns the mirrored tree and accepts rsync.";
      };

      senderKey = lib.mkOption {
        type = nullOr str;
        default = null;
        description = "SSH public key permitted to write this mirror.";
      };
    };

    sender = {
      enable = lib.mkEnableOption "a nightly rsync download mirror sender";

      sourceDir = lib.mkOption {
        type = str;
        default = "/var/www/dl";
      };

      destination = lib.mkOption {
        type = nullOr str;
        default = null;
        example = "dl-receiver@dl2.example.org";
        description = "Restricted rsync receiver, without a destination path.";
      };

      identityFile = lib.mkOption {
        type = str;
        default = "/etc/ssh/ssh_host_ed25519_key";
        description = "SSH private key whose public half is accepted by the receiver.";
      };

      onCalendar = lib.mkOption {
        type = str;
        default = "*-*-* 03:00:00 UTC";
      };

      randomizedDelaySec = lib.mkOption {
        type = str;
        default = "30m";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf receiver.enable {
      assertions = [
        {
          assertion = receiver.domain != null;
          message = "mj.services.dl-mirror.receiver.domain must be set when the receiver is enabled";
        }
        {
          assertion = receiver.senderKey != null;
          message = "mj.services.dl-mirror.receiver.senderKey must be set when the receiver is enabled";
        }
      ];

      services.caddy.enable = true;
      services.caddy.virtualHosts.${receiver.domain}.extraConfig = ''
        header Alt-Svc "h3=\":443\"; ma=86400"
        root * ${receiver.dataDir}
        file_server browse {
          hide .stfolder
        }
        encode gzip
      '';

      users = {
        users.${receiver.user} = {
          description = "Restricted download mirror receiver";
          isSystemUser = true;
          group = receiver.user;
          # sshd runs forced commands through the account's shell.
          shell = pkgs.dash;
          openssh.authorizedKeys.keys = [
            ''command="${pkgs.rrsync}/bin/rrsync -wo ${receiver.dataDir}",restrict ${receiver.senderKey}''
          ];
        };
        groups.${receiver.user} = { };
      };

      systemd.tmpfiles.rules = [ "d ${receiver.dataDir} 0755 ${receiver.user} ${receiver.user} -" ];
    })

    (lib.mkIf sender.enable {
      assertions = [
        {
          assertion = sender.destination != null;
          message = "mj.services.dl-mirror.sender.destination must be set when the sender is enabled";
        }
      ];

      systemd = {
        services.dl-mirror = {
          description = "Mirror ${sender.sourceDir} to ${sender.destination}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            LoadCredential = [ "ssh-key:${sender.identityFile}" ];
          };
          script = ''
            exec ${pkgs.rsync}/bin/rsync \
              --archive \
              --no-owner \
              --no-group \
              --delete \
              --chmod=ugo-w,a+rX,u+w \
              --rsh="${pkgs.openssh}/bin/ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts" \
              ${sender.sourceDir}/ \
              ${sender.destination}:
          '';
        };

        timers.dl-mirror = {
          description = "Nightly download mirror";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = sender.onCalendar;
            Persistent = true;
            RandomizedDelaySec = sender.randomizedDelaySec;
          };
        };
      };
    })
  ];
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkUnlock =
    {
      sshEndpoint,
      pingEndpoint,
      remotePubkey,
      pwFile,
      pingTimeoutSec,
    }:
    let
      timeoutStr = builtins.toString pingTimeoutSec;
    in
    ''
      set -x
      # if host is reachable via "pingEndpoint", which, we presume is
      # VPN (which implies the rootfs has been unlocked for VPN to work),
      # exit successfully.
      ${pkgs.iputils}/bin/ping -q -W ${timeoutStr} -c 1 ${pingEndpoint} && exit 0

      exec ${pkgs.openssh}/bin/ssh \
          -i /etc/ssh/ssh_host_ed25519_key \
          -o UserKnownHostsFile=none \
          -o GlobalKnownHostsFile=/dev/null \
          -o KnownHostsCommand="${pkgs.coreutils}/bin/echo ${sshEndpoint} ${remotePubkey}" \
          root@${sshEndpoint} < "${pwFile}"
    '';
in
{
  options.mj.services.zfsunlock = with lib.types; {
    enable = lib.mkEnableOption "remotely unlock zfs-encrypted root volumes";

    targets = lib.mkOption {
      default = { };
      type = attrsOf (submodule {
        options = {
          sshEndpoint = lib.mkOption { type = str; };
          pingEndpoint = lib.mkOption { type = str; };
          pingTimeoutSec = lib.mkOption {
            type = int;
            default = 20;
          };
          remotePubkey = lib.mkOption { type = str; };
          pwFile = lib.mkOption { type = path; };
          startAt = lib.mkOption { type = either str (listOf str); };
        };
      });
    };
  };

  config = lib.mkIf config.mj.services.zfsunlock.enable {
    systemd.services = lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair "zfsunlock-${name}" {
        description = "zfsunlock service for ${name}";
        script = mkUnlock (builtins.removeAttrs cfg [ "startAt" ]);
        serviceConfig = {
          User = "root";
          ProtectSystem = "strict";
        };
      }
    ) config.mj.services.zfsunlock.targets;

    systemd.timers = lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair "zfsunlock-${name}" {
        description = "zfsunlock timer for ${name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.startAt;
        };
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      }
    ) config.mj.services.zfsunlock.targets;

    mj.base.unitstatus.units = map (name: "zfsunlock-${name}") (
      builtins.attrNames config.mj.services.zfsunlock.targets
    );
  };
}

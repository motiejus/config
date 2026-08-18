{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.mj.services.timelapse-r11;
  stateDir = "/var/lib/timelapse-r11";

  timelapseScript = pkgs.writeShellApplication {
    name = "timelapse-r11";
    runtimeInputs = with pkgs; [ ffmpeg-headless ];
    text = ''
      set -x
      NOW=$(date +%F_%T)
      DATE=''${NOW%_*}
      mkdir -p /var/lib/timelapse-r11/{ptz,panorama}/"''${DATE}"
      EXITCODE=0
      ffmpeg -hide_banner -y \
        -rtsp_transport tcp \
        -i "rtsp://timelapse:''${TIMELAPSE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0" \
        -vframes 1 \
        "/var/lib/timelapse-r11/ptz/''${DATE}/''${NOW}.jpg" || EXITCODE=$?

      ffmpeg -hide_banner -y \
        -rtsp_transport tcp \
        -i "rtsp://timelapse:''${TIMELAPSE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=0" \
        -vframes 1 \
        "/var/lib/timelapse-r11/panorama/''${DATE}/''${NOW}.jpg" || EXITCODE=$?

      exit "$EXITCODE"
    '';
  };

  # Shared by the two units below: same user, same state directory, same sandbox.
  common = {
    StateDirectory = "timelapse-r11";
    StateDirectoryMode = "0750";
    User = "timelapse-r11";
    Group = "timelapse-r11";

    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    RemoveIPC = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallArchitectures = "native";
    PrivateUsers = true;
    PrivateDevices = true;
    MemoryDenyWriteExecute = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
  };

in
{
  options.mj.services.timelapse-r11 = with lib.types; {
    enable = lib.mkEnableOption "enable timelapse-r11";
    secretsEnv = lib.mkOption { type = path; };
    onCalendar = lib.mkOption { type = str; };
    archiveFrom = lib.mkOption {
      type = nullOr str;
      default = null;
      example = "timelapse-r11@fwminex.jakst.vpn";
      description = ''
        [USER@]HOST keeping a second copy of the same cameras' stills. Setting it
        turns on the nightly archive job: backfill this host's outages from
        there, turn finished days and months into video, and delete the stills of
        any month that is old enough and whose video verifies. Null leaves the
        archive to be driven by hand.
      '';
    };

    readerKeys = lib.mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        SSH public keys allowed to read this host's stills, so that another host
        can run timelapse-merger against it. Each key is pinned to a read-only
        rrsync rooted at the state directory: it can run nothing but rsync, can
        only read, and cannot address a path outside that directory.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    mj.base.unitstatus.units = [
      "timelapse-r11"
    ]
    ++ lib.optional (cfg.archiveFrom != null) "timelapse-archive";

    users.users.timelapse-r11 = {
      isSystemUser = true;
      group = "timelapse-r11";
      # sshd runs the forced command through the account's shell.
      shell = lib.mkIf (cfg.readerKeys != [ ]) pkgs.bashInteractive;
      openssh.authorizedKeys.keys = map (
        k: ''command="${pkgs.rrsync}/bin/rrsync -ro ${stateDir}",restrict ${k}''
      ) cfg.readerKeys;
    };

    users.groups.timelapse-r11 = {
      members = [ "motiejus" ];
    };

    systemd.services = {

      # One pass over the whole archive: backfill, encode the days that ended,
      # join the months that are complete, then delete the stills of a month old
      # enough to give up and verified frame by frame.
      #
      # Deleting is its own ExecStart on purpose. Drop that line and the archive
      # keeps building itself while every photo stays on disk; nothing else about
      # the job changes.
      timelapse-archive = lib.mkIf (cfg.archiveFrom != null) {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = common // {
          ExecStart = [
            "${lib.getExe pkgs.timelapse-daily} --missing-from=${cfg.archiveFrom}"
            (lib.getExe pkgs.timelapse-reap)
          ];
          Type = "oneshot";
          # A day of footage is minutes of encoding per camera and a first run has
          # the entire backlog to work through, so there is no useful timeout: the
          # work is idempotent and the next run picks up wherever this one stopped.
          TimeoutStartSec = "infinity";
          Nice = 19;
          IOSchedulingClass = "idle";
          # Neither -threads nor svt's lp bounds the encoder: it starts ~127
          # threads either way, so the bound has to come from the cgroup. A cpuset
          # caps how much of the machine it can take without CPUQuota throttling
          # every thread each period. Sized for fwminex (8 cores/16 threads).
          AllowedCPUs = "0-7";
          # Measured peak is 7.8G for a day of 5376x1520 at these four cores, so
          # this is headroom, not a target. Being killed costs one night: the run
          # is idempotent and the next one resumes from the files on disk, and the
          # failure is mailed instead of being absorbed by everything else here.
          MemoryMax = "10G";

          # AF_UNIX on top of the capture unit's set: resolving the other host's
          # name goes through a local socket before any packet is sent.
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
      timelapse-r11 = {
        preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/timelapse-r11/secrets.env";
        serviceConfig = common // {
          ExecStart = lib.getExe timelapseScript;
          # This one shells out to bare date, so it needs telling; the archive
          # tools export TZ themselves.
          Environment = [ "TZ=UTC" ];
          EnvironmentFile = [ "-/run/timelapse-r11/secrets.env" ];
          LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
          RuntimeDirectory = "timelapse-r11";
          Type = "simple";
          RuntimeMaxSec = "55s";

          # The camera is addressed by IP, so this one needs no name resolution.
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
    };

    systemd.timers = {
      timelapse-archive = lib.mkIf (cfg.archiveFrom != null) {
        timerConfig = {
          OnCalendar = "*-*-* 04:00:00 UTC";
          Persistent = true;
        };
        wantedBy = [ "timers.target" ];
      };

      timelapse-r11 = {
        timerConfig.OnCalendar = cfg.onCalendar;
        wantedBy = [ "timers.target" ];
      };
    };

  };

}

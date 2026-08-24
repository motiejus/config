{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.mj.services.timelapse-r11;
  stateDir = "/var/lib/timelapse-r11";
  webRoot = "/var/www/timelapse-web";

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

  # Shared baseline sandbox for the units below.
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
        there and turn finished days and months into video. Null leaves the
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

    web.enable = lib.mkEnableOption "publish the timelapse archive as a static web site";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.web.enable || cfg.archiveFrom != null;
        message = "mj.services.timelapse-r11.web requires archiveFrom, which drives timelapse-web after a successful archive";
      }
    ];

    mj.base.unitstatus.units = [
      "timelapse-r11"
    ]
    ++ lib.optional (cfg.archiveFrom != null) "timelapse-archive"
    ++ lib.optional cfg.web.enable "timelapse-web";

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

    systemd = {
      tmpfiles.rules = lib.optional cfg.web.enable "d ${webRoot} 0755 timelapse-r11 timelapse-r11 -";

      services = {
        # One pass over the whole archive, oldest month first: backfill it from the
        # other host, encode the days that ended, join the months that are complete.
        #
        # Deleting is its own ExecStart on purpose, and it is commented out: the
        # archive keeps building itself while every photograph stays on disk, which
        # is where this stays until the pipeline has been watched for a while.
        timelapse-archive = lib.mkIf (cfg.archiveFrom != null) {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig = lib.optionalAttrs cfg.web.enable {
            # OnSuccess belongs to the producer: systemd starts the static-site
            # publisher only after a successful archive pass, never the reverse.
            OnSuccess = [ "timelapse-web.service" ];
          };
          serviceConfig = common // {
            ExecStart = [
              "${lib.getExe pkgs.timelapse-daily} --missing-from=${cfg.archiveFrom}"
              # (lib.getExe pkgs.timelapse-reap)
            ];
            Type = "oneshot";
            # A day of footage is minutes of encoding per camera and a first run has
            # the entire backlog to work through, so there is no useful timeout: the
            # work is idempotent and the next run picks up wherever this one stopped.
            TimeoutStartSec = "infinity";
            # The package override fixes natural EOF, but even fixed libsvtav1 cannot
            # interrupt an active encode promptly; bound SIGKILL escalation separately.
            TimeoutStopSec = "10s";
            Nice = 19;
            IOSchedulingClass = "idle";
            AllowedCPUs = "0-11";
            MemoryMax = "10G";

            # The encoder runs on the GPU, so the render node has to be reachable at
            # all: PrivateDevices replaces /dev with a set that has no render node in
            # it, and the node is root:render 0660. Nothing else in the sandbox above
            # is in the way -- traced through a real av1_vaapi encode, mesa maps no
            # page write+executable and uses no privileged syscall.
            PrivateDevices = false;
            DeviceAllow = [ "/dev/dri/renderD128 rw" ];
            SupplementaryGroups = [ "render" ];
            # Mesa opens a shader cache at startup even though VCN compiles no
            # shaders; without a writable one it warns into the journal every night.
            CacheDirectory = "timelapse-r11";
            Environment = [ "XDG_CACHE_HOME=/var/cache/timelapse-r11" ];

            # AF_UNIX on top of the capture unit's set: resolving the other host's
            # name goes through a local socket before any packet is sent.
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
          };
        };
        timelapse-web = lib.mkIf cfg.web.enable {
          # Keeps the ordering sensible when started manually alongside the
          # archive. The archive's OnSuccess remains the normal trigger.
          after = [ "timelapse-archive.service" ];
          serviceConfig = common // {
            # tmpfiles owns the generated, world-readable nginx tree. The
            # publisher also reaps stale source artifacts, so both it and the
            # capture state must be writable through ProtectSystem=strict.
            WorkingDirectory = webRoot;
            ReadWritePaths = [
              stateDir
              webRoot
            ];
            ExecStart = "${lib.getExe pkgs.timelapse-web} ${stateDir}/videos";
            Type = "oneshot";
            TimeoutStartSec = "infinity";
            TimeoutStopSec = "10s";
            Nice = 19;
            IOSchedulingClass = "idle";
            AllowedCPUs = "0-11";
            MemoryMax = "10G";

            # The publisher uses VAAPI for every HLS rendition and thumbnail.
            PrivateDevices = false;
            DeviceAllow = [ "/dev/dri/renderD128 rw" ];
            SupplementaryGroups = [ "render" ];
            CacheDirectory = "timelapse-web";
            Environment = [
              "TIMELAPSE_WEB_ROOT=${webRoot}"
              "XDG_CACHE_HOME=/var/cache/timelapse-web"
              "LIBVA_DRIVER_NAME=radeonsi"
            ];

            RestrictAddressFamilies = [ "AF_UNIX" ];
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

      timers = {
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
  };

}

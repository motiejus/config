{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.frigate;
  python3-fp = pkgs.python312.overrideAttrs (_: {
    EXTRA_CFLAGS = " -fno-omit-frame-pointer";
  });
in
{
  options.mj.services.frigate = with lib.types; {
    enable = lib.mkEnableOption "enable frigate";
    secretsEnv = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.frigate = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/frigate/secrets.env";
      serviceConfig = {
        ExecStart = lib.mkForce "${lib.getExe python3-fp} -m frigate";
        EnvironmentFile = [ "-/run/frigate/secrets.env" ];
        Environment = [ "PYTHONPERFSUPPORT=1" ];
        RuntimeDirectory = "frigate";
        LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
      };
    };

    services.frigate = {
      enable = true;
      hostname = "r1.jakstys.lt";
      settings = {
        detect = {
          enabled = true;
        };
        detectors = {
          coral = {
            type = "edgetpu";
            device = "usb";
            enabled = true;
          };
        };
        record = {
          enabled = true;
          retain = {
            days = 7;
            mode = "all";
          };
        };
        cameras = {
          vno4-dome-panorama = {
            enabled = true;
            ffmpeg = {
              hwaccel_args = "preset-vaapi";
              output_args = {
                record = "preset-record-generic-audio-copy";
              };
              inputs = [
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=0";
                  roles = [
                    "audio"
                    "record"
                  ];
                }
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=1";
                  roles = [ "detect" ];
                }
              ];
            };
          };
          vno4-dome-ptz = {
            enabled = true;
            ffmpeg = {
              output_args = {
                record = "preset-record-generic-audio-copy";
              };
              inputs = [
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0";
                  roles = [
                    "audio"
                    "record"
                  ];
                }
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=1";
                  roles = [ "detect" ];
                }
              ];
            };
          };
        };
      };
    };

  };
}

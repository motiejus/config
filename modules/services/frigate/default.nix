{
  lib,
  #pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.frigate;
in
{
  options.mj.services.frigate = with lib.types; {
    enable = lib.mkEnableOption "enable frigate";
    secretsEnv = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      frigate = {
        preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/frigate/secrets.env";
        serviceConfig = {
          EnvironmentFile = [ "-/run/frigate/secrets.env" ];
          RuntimeDirectory = "frigate";
          LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
        };
      };

      go2rtc = {
        preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/go2rtc/secrets.env";
        serviceConfig = {
          EnvironmentFile = [ "-/run/go2rtc/secrets.env" ];
          RuntimeDirectory = "go2rtc";
          LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
        };
      };
    };

    services.go2rtc = {
      enable = true;
      settings = {
        streams = {
          "vno4-dome-panorama-high" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=0"
          ];
          "vno4-dome-panorama-low" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=1"
          ];
          "vno4-dome-ptz-high" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0"
          ];
          "vno4-dome-ptz-low" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=1"
          ];
        };
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
                  path = "rtsp://localhost:8554/vno4-dome-panorama-high";
                  roles = [
                    "audio"
                    "record"
                  ];
                }
                {
                  path = "rtsp://localhost:8554/vno4-dome-panorama-low";
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
                  path = "rtsp://localhost:8554/vno4-dome-ptz-high";
                  roles = [
                    "audio"
                    "record"
                  ];
                }
                {
                  path = "rtsp://localhost:8554/vno4-dome-ptz-low";
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

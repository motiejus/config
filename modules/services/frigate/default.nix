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
        # https://github.com/AlexxIT/go2rtc/issues/831
        #log = {
        #  format = "text";
        #  level = "trace";
        #};
        streams = {
          "vno4-dome-panorama-orig" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=2"
          ];
          "vno4-dome-panorama-high" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-panorama-orig#hardware=vaapi#video=h264"
          ];
          "vno4-dome-panorama-low" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-panorama-orig#hardware=vaapi#video=h264#width=1280#framerate=5"
          ];
          "vno4-dome-ptz-orig" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0"
          ];
          "vno4-dome-ptz-high" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264"
          ];
          "vno4-dome-ptz-low" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#width=1280#framerate=5"
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
                record = "preset-record-generic";
              };
              inputs = [
                {
                  path = "rtsp://localhost:8554/vno4-dome-panorama-high";
                  roles = [ "record" ];
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
                    "record"
                    "audio"
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

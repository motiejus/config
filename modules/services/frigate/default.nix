{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.frigate;
  timelapseScript = pkgs.writeShellApplication {
    name = "timelapse-r11";
    runtimeInputs = with pkgs; [ ffmpeg ];
    text = ''
      set -x
      NOW=$(date +%F_%T)
      DATE=''${NOW%_*}
      TIME=''${NOW#*_}
      mkdir -p /var/lib/timelapse-r11/"''${DATE}"
      exec ffmpeg -y \
        -rtsp_transport tcp \
        -i "rtsp://frigate:''${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0" \
        -vframes 1 \
        /var/lib/timelapse-r11/"''${DATE}"/"''${TIME}.jpg"
    '';
  };
in
{
  options.mj.services.frigate = with lib.types; {
    enable = lib.mkEnableOption "enable frigate";
    secretsEnv = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    mj.base.unitstatus.units = [
      "timelapse-r11"
      "go2rtc"
      "frigate"
    ];

    systemd.timers.timelapse-r11 = {
      timerConfig.OnCalendar = "*-*-* 7..19:00,30:00 Europe/Vilnius";
      wantedBy = [ "timers.target" ];
    };

    systemd.services = {
      timelapse-r11 = {
        preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/timelapse-r11/secrets.env";
        serviceConfig = {
          ExecStart = lib.getExe timelapseScript;
          EnvironmentFile = [ "-/run/timelapse-r11/secrets.env" ];
          LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
          RuntimeDirectory = "timelapse-r11";
          StateDirectory = "timelapse-r11";
          DynamicUser = true;
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
            "ffmpeg:rtsp://localhost:8554/vno4-dome-panorama-orig#hardware=vaapi#video=h264#width=1280"
          ];
          "vno4-dome-ptz-orig" = [
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0#video=copy#audio=copy"
          ];
          "vno4-dome-ptz-high" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#audio=copy"
          ];
          "vno4-dome-ptz-low" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#audio=copy#width=1280"
          ];
        };
      };
    };

    services.frigate = {
      enable = true;
      hostname = "r1.jakstys.lt";
      settings = {
        ffmpeg.hwaccel_args = "preset-vaapi";
        detect = {
          enabled = true;
          fps = 5;
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

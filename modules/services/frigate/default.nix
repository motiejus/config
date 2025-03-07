{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.frigate;

  proberScript = pkgs.writeShellApplication {
    name = "go2rtc-prober";
    runtimeInputs = with pkgs; [
      systemd
      ffmpeg
    ];
    text = ''
      set -x
      while true; do
        FAILED=0

        for input in vno4-dome-{panorama,ptz}-{orig,high,low}; do
          timeout 30s \
            ffprobe -hide_banner "rtsp://localhost:8554/''${input}" || FAILED=1
        done

        [[ "$FAILED" == 1 ]] && systemctl restart --no-block go2rtc.service

        sleep 5m
      done
    '';
  };
  timelapseScript = pkgs.writeShellApplication {
    name = "timelapse-r11";
    runtimeInputs = with pkgs; [ ffmpeg ];
    text = ''
      set -x
      NOW=$(date +%F_%T)
      DATE=''${NOW%_*}
      TIME=''${NOW#*_}
      mkdir -p /var/lib/timelapse-r11/"''${DATE}"
      EXITCODE=0
      ffmpeg -hide_banner -y \
        -rtsp_transport tcp \
        -i "rtsp://frigate:''${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0" \
        -vframes 1 \
        /var/lib/timelapse-r11/"''${DATE}"/"ptz-''${TIME}.jpg" || EXITCODE=$?

      ffmpeg -hide_banner -y \
        -rtsp_transport tcp \
        -i "rtsp://frigate:''${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=0" \
        -vframes 1 \
        /var/lib/timelapse-r11/"''${DATE}"/"panorama-''${TIME}.jpg" || EXITCODE=$?

      exit "$EXITCODE"
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
      timerConfig.OnCalendar = "*-*-* 7..19:00,5:00 Europe/Vilnius";
      wantedBy = [ "timers.target" ];
    };

    systemd.services = {
      go2rtc-prober = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.getExe proberScript;
          RestartSec = 300;
          Restart = "always";
        };
      };
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
            #"ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0#video=copy#audio=copy"
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0#video=copy"
          ];
          "vno4-dome-ptz-high" = [
            #"ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#audio=copy"
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264"
          ];
          "vno4-dome-ptz-low" = [
            #"ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#width=1280#audio=copy"
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#width=1280"
          ];
        };
      };
    };

    services.frigate = {
      enable = true;
      hostname = "r1.jakstys.lt";
      settings = {
        ffmpeg.hwaccel_args = "preset-vaapi";

        mqtt = {
          enabled = true;
          host = "::";
        };

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
                #record = "preset-record-generic";
              };
              inputs = [
                {
                  path = "rtsp://localhost:8554/vno4-dome-ptz-high";
                  roles = [
                    "record"
                    #"audio"
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

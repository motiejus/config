{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.frigate;
  sklypas = "0.312,1,0.311,0.269,0.354,0.172,0.396,0.154,0.431,0.102,0.495,0.044,0.61,0.039,0.774,0.097,0.837,0.219,0.758,0.995";

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
in
{
  options.mj.services.frigate = with lib.types; {
    enable = lib.mkEnableOption "enable frigate";
    secretsEnv = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    mj.base.unitstatus.units = [
      "go2rtc"
      "frigate"
    ];

    systemd.services = {
      go2rtc-prober = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.getExe proberScript;
          RestartSec = 300;
          Restart = "always";
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
            "ffmpeg:rtsp://frigate:\${FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=2#video=copy#audio=copy"
          ];
          "vno4-dome-ptz-high" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#audio=copy"
          ];
          "vno4-dome-ptz-low" = [
            "ffmpeg:rtsp://localhost:8554/vno4-dome-ptz-orig#hardware=vaapi#video=h264#width=1280#audio=copy"
          ];
        };
      };
    };

    services.frigate = {
      enable = true;
      hostname = "r1.jakstys.lt";
      settings = {
        #ui.strftime_fmt = "%F %T";
        ffmpeg.hwaccel_args = "preset-vaapi";
        telemetry.version_check = false;

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
          sync_recordings = true;
          retain = {
            days = 7;
            mode = "all";
          };
          events = {
            pre_capture = 5;
            post_capture = 5;
            retain = {
              default = 30;
              mode = "motion";
            };
          };
        };

        cameras = {
          vno4-dome-panorama =
            let
              masks = [
                "0.269,0.285,0.235,0.567,0.194,0.634,0.095,1,0,1,0,0,0.321,0,0.323,0.222"
                "0.766,1,0.855,0.123,0.818,0.104,0.818,0,1,0,1,1"
              ];
            in
            {
              enabled = true;
              motion.mask = masks;
              objects = {
                mask = masks;
                track = [
                  "bicycle"
                  "car"
                  "dog"
                  "motorcycle"
                  "person"
                ];
              };
              zones.sklypas.coordinates = sklypas;

              review = {
                alerts.required_zones = [ "sklypas" ];
                detections.required_zones = [ "sklypas" ];
              };

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

          vno4-dome-ptz =
            let
              masks = [ "0.666,0.095,1,0.095,1,0,0.666,0" ];
            in
            {
              enabled = true;
              motion.mask = masks;
              objects.mask = masks;

              audio = {
                enabled = true;
                listen = [ "speech" ];
              };

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

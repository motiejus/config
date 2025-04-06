{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.mj.services.timelapse-r11;

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

in
{
  options.mj.services.timelapse-r11 = with lib.types; {
    enable = lib.mkEnableOption "enable timelapse-r11";
    secretsEnv = lib.mkOption { type = path; };
    onCalendar = lib.mkOption { type = str; };
  };

  config = lib.mkIf cfg.enable {
    mj.base.unitstatus.units = [ "timelapse-r11" ];

    systemd.timers.timelapse-r11 = {
      timerConfig.OnCalendar = cfg.onCalendar;
      wantedBy = [ "timers.target" ];
    };

    systemd.services.timelapse-r11 = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/timelapse-r11/secrets.env";
      serviceConfig = {
        ExecStart = lib.getExe timelapseScript;
        Environment = [ "TZ=Europe/Vilnius" ];
        EnvironmentFile = [ "-/run/timelapse-r11/secrets.env" ];
        LoadCredential = [ "secrets.env:${cfg.secretsEnv}" ];
        RuntimeDirectory = "timelapse-r11";
        StateDirectory = "timelapse-r11";
        DynamicUser = true;
        Type = "simple";
        RuntimeMaxSec = "55s";
      };
    };

  };

}

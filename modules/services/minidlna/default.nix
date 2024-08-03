{ config, lib, ... }:
let
  cfg = config.mj.services.minidlna;
in
{
  options.mj.services.minidlna = with lib.types; {
    enable = lib.mkEnableOption "Enable minidlna";
    paths = lib.mkOption { type = listOf path; };
  };

  config = lib.mkIf cfg.enable {
    services.minidlna = {
      enable = true;
      openFirewall = true;
      settings = {
        media_dir = cfg.paths;
        friendly_name = "${config.networking.hostName}.${config.networking.domain}";
        inotify = "yes";
      };
    };

    systemd.services.minidlna = {
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = cfg.paths;
      };
    };

  };

}

{ config, lib, ... }:
let
  cfg = config.mj.services.syncthing-relay;
in
{
  options.mj.services.syncthing-relay = with lib.types; {
    enable = lib.mkEnableOption "enable syncthing-relay";
  };

  config = lib.mkIf cfg.enable {
    services.syncthing.relay = {
      enable = true;
      providedBy = "jakstys.lt";
    };
    systemd.services.syncthing-relay.restartIfChanged = false;

    networking.firewall.allowedTCPPorts = [
      config.services.syncthing.relay.port
      config.services.syncthing.relay.statusPort
    ];
  };

}

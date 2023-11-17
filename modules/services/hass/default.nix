{
  config,
  lib,
  pkgs,
  myData,
  ...
}: let
  cfg = config.mj.services.hass;
in {
  options.mj.services.hass = with lib.types; {
    enable = lib.mkEnableOption "Enable home-assistant";
  };

  config = lib.mkIf cfg.enable {
    mj.services.friendlyport.ports = [
      {
        subnets = [myData.subnets.tailscale.cidr];
        tcp = [myData.ports.hass];
      }
      {
        subnets = myData.subnets.motiejus.cidrs;
        tcp = [config.services.esphome.port];
      }
    ];

    environment.systemPackages = [pkgs.esphome]; # so it lands in PATH

    services = {
      esphome = {
        enable = true;
        address = "0.0.0.0";
      };

      home-assistant = {
        enable = true;
        extraComponents = [
          "esphome"
          "met"
          "radio_browser"

          # my stuff
          "yamaha_musiccast"
          "dlna_dmr"
          "shelly"
          "webostv"
        ];
        config = {
          default_config = {};

          http = {
            use_x_forwarded_for = true;
            trusted_proxies = ["127.0.0.1"];
          };
          homeassistant = {
            auth_providers = [
              {
                type = "trusted_networks";
                trusted_networks = myData.subnets.motiejus.cidrs;
              }
            ];
          };

          wake_on_lan = {};

          # requires a restore from backup
          "automation ui" = "!include automations.yaml";
          "automation yaml" = [
            {
              alias = "Turn On Living Room TV with WakeOnLan";
              trigger = [
                {
                  platform = "webostv.turn_on";
                  entity_id = "media_player.lg_webos_smart_tv";
                }
              ];
              action = [
                {
                  service = "wake_on_lan.send_magic_packet";
                  data = {mac = "74:e6:b8:4c:fb:b7";};
                }
              ];
            }
          ];
        };
      };
    };
  };
}

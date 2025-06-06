{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.hass;
in
{
  options.mj.services.hass = with lib.types; {
    enable = lib.mkEnableOption "Enable home-assistant";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ ];

    services = {
      mosquitto = {
        enable = true;
        listeners = [
          {
            address = "::";
            acl = [ "pattern readwrite #" ];
            omitPasswordAuth = true;
            settings.allow_anonymous = true;
          }
        ];
      };

      home-assistant = {
        enable = true;
        extraComponents = [
          "met"
          "radio_browser"

          # my stuff
          "yamaha_musiccast"
          "dlna_dmr"
          "shelly"
          "webostv"
          "daikin"
          "ipp"
          "prometheus"
          "mqtt"
        ];
        customComponents = [
          pkgs.home-assistant-custom-components.frigate
        ];
        config = {
          default_config = { };

          http = {
            use_x_forwarded_for = true;
            trusted_proxies = [ "127.0.0.1" ];
          };
          homeassistant = {
            auth_providers = [
              { type = "homeassistant"; }
              {
                # TODO trust a subset
                type = "trusted_networks";
                trusted_networks = myData.subnets.tailscale.cidr;
              }
            ];
          };

          wake_on_lan = { };

          prometheus = {
            namespace = "hass";
            requires_auth = false;
          };

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
                  data = {
                    mac = "74:e6:b8:4c:fb:b7";
                  };
                }
              ];
            }
          ];
        };
      };
    };
  };
}

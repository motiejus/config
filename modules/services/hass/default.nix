{
  config,
  lib,
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
        subnets = myData.subnets.vpn.cidrs;
        tcp = [myData.ports.hass];
      }
    ];

    services = {
      home-assistant = {
        enable = true;
        extraComponents = [
          "esphome"
          "met"
          "radio_browser"
        ];
        config = {
          auth_providers = {
            trusted_networks = [myData.subnets.tailscale.cidr];
            #trusted_proxies = ["127.0.0.1"];
          };
          default_config = {};
        };
      };
    };
  };
}

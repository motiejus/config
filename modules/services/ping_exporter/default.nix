{
  config,
  lib,
  myData,
  ...
}:
let
  cfg = config.mj.services.ping_exporter;
in
{
  options.mj.services.ping_exporter = with lib.types; {
    enable = lib.mkEnableOption "Enable ping_exporter";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.ping = {
      enable = true;
      settings = {
        options.disableIPv6 = true;
        ping = {
          interval = "1s";
          timeout = "5s";
          history-size = 10;
        };
        targets = [
          "1.1.1.1"
          "8.8.4.4"
          "fb.com"
          "rrt.lt"
          "kam.lt"
          "lrs.lt"
          "15min.lt"

          "fra1-b.jakstys.lt"
          myData.hosts."fra1-b.servers.jakst".jakstIP
        ];
      };
    };

    mj.services.friendlyport.ports = [
      {
        subnets = [ myData.subnets.tailscale.cidr ];
        tcp = [ config.services.prometheus.exporters.ping.port ];
      }
    ];
  };
}

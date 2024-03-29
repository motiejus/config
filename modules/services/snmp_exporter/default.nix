{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
  options.mj.services.snmp_exporter = with lib.types; {
    enable = lib.mkEnableOption "Enable prometheus snmp_exporter";
  };

  config = lib.mkIf config.mj.services.snmp_exporter.enable {
    mj.services.friendlyport.ports = [
      {
        subnets = [myData.subnets.tailscale.cidr];
        tcp = [config.services.prometheus.exporters.snmp.port];
      }
    ];

    services.prometheus.exporters.snmp = {
      enable = true;
      configurationPath = pkgs.concatTextFile {
        name = "snmp.yml";
        files = [./snmp.yml];
      };
    };
  };
}

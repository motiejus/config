{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.snmp_exporter = with lib.types; {
    enable = lib.mkEnableOption "Enable prometheus snmp_exporter";
  };

  config = lib.mkIf config.mj.services.snmp_exporter.enable {
    mj.services.friendlyport.vpn.ports = [config.services.prometheus.exporters.snmp.port];

    services.prometheus.exporters.snmp = {
      enable = true;
      listenAddress = "127.0.0.1";
      configurationPath = ./snmp.yml;
    };

  };
}

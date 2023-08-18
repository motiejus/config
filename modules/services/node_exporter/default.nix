{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.node_exporter = with lib.types; {
    enable = lib.mkEnableOption "Enable node_exporter";
  };

  config = lib.mkIf config.mj.services.node_exporter.enable {
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = ["systemd" "processes"];
      port = myData.ports.exporters.node;
    };

    mj.services.friendlyport.vpn.ports = [
      myData.ports.exporters.node
    ];
  };
}

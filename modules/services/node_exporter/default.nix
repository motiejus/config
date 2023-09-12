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
      user = "node_exporter";
      group = "node_exporter";
    };

    users.users.node_exporter = {
      isSystemUser = true;
      group = "node_exporter";
      uid = myData.uidgid.node_exporter;
    };

    users.groups.node_exporter = {
      gid = myData.uidgid.node_exporter;
    };

    mj.services.friendlyport.ports = [
      {
        subnets = [myData.subnets.tailscale.cidr];
        tcp = [myData.ports.exporters.node];
      }
    ];
  };
}

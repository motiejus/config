{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.friendlyport = with lib.types; {
    ports = lib.mkOption {
      type = listOf int;
      default = [];
    };
  };

  config = let
    ports = builtins.concatStringsSep "," (map builtins.toString config.mj.services.friendlyport.ports);
    hosts = lib.attrVals ["mxp10.motiejus.jakst" "fwmine.motiejus.jakst"] myData.hosts;
    ips = lib.catAttrs "jakstIP" hosts;
    startLines = map (ip: "iptables -A INPUT -p tcp --match multiport --dports ${ports} --source ${ip} -j ACCEPT") ips;
    # TODO: when stopping the firewall, systemd uses the old ports. So this is a two-phase process.
    # How to stop the old one and start the new one?
    stopLines = map (ip: "iptables -D INPUT -p tcp --match multiport --dports ${ports} --source ${ip} -j ACCEPT || :") ips;
  in {
    networking.firewall.extraCommands = lib.concatLines startLines;
    networking.firewall.extraStopCommands = lib.concatLines stopLines;
  };
}

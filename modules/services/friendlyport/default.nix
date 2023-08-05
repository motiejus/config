{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.friendlyport.motiejus = with lib.types; {
    ports = lib.mkOption {
      type = listOf int;
      default = [];
    };
  };
  options.mj.services.friendlyport.vpn = with lib.types; {
    ports = lib.mkOption {
      type = listOf int;
      default = [];
    };
  };

  config = let
    portsM = config.mj.services.friendlyport.motiejus.ports;
    portsV = config.mj.services.friendlyport.vpn.ports;
    portsMStr = builtins.concatStringsSep "," (map builtins.toString config.mj.services.friendlyport.motiejus.ports);
    portsVStr = builtins.concatStringsSep "," (map builtins.toString config.mj.services.friendlyport.vpn.ports);
    hosts = lib.attrVals ["mxp10.motiejus.jakst" "fwmine.motiejus.jakst"] myData.hosts;
    ips = lib.catAttrs "jakstIP" hosts;
    startLinesM =
      if builtins.length portsM > 0
      then map (ip: "iptables -A INPUT -p tcp --match multiport --dports ${portsMStr} --source ${ip} -j ACCEPT") ips
      else [];
    startLinesV =
      if builtins.length portsV > 0
      then "iptables -A INPUT -p tcp --match multiport --dports ${portsVStr} --source ${myData.tailscale_subnet.cidr} -j ACCEPT"
      else "";

    # TODO: when stopping the firewall, systemd uses the old ports. So this is a two-phase process.
    # How to stop the old one and start the new one?
    stopLinesM =
      if builtins.length portsM > 0
      then map (ip: "iptables -D INPUT -p tcp --match multiport --dports ${portsMStr} --source ${ip} -j ACCEPT || :") ips
      else [];
    stopLinesV =
      if builtins.length portsV > 0
      then "iptables -D INPUT -p tcp --match multiport --dports ${portsVStr} --source ${myData.tailscale_subnet.cidr} -j ACCEPT || :"
      else "";
  in {
    networking.firewall.extraCommands = lib.concatLines (startLinesM ++ [startLinesV]);
    networking.firewall.extraStopCommands = lib.concatLines (stopLinesM ++ [stopLinesV]);
  };
}

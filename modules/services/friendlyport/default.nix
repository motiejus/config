{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.friendlyport = with lib.types; {
    ports = lib.mkOption {
      type = listOf (submodule (
        {...}: {
          options = {
            subnets = lib.mkOption {type = listOf str;};
            tcp = lib.mkOption {
              type = listOf int;
              default = [];
            };
            udp = lib.mkOption {
              type = listOf int;
              default = [];
            };
          };
        }
      ));
    };
  };

  config = let
    ports = config.mj.services.friendlyport.ports;
    mkAdd = (
      proto: subnets: ints: let
        subnetsS = builtins.concatStringsSep "," subnets;
        intsS = builtins.concatStringsSep "," (map builtins.toString ints);
      in
        if builtins.length ints == 0
        then ""
        else "iptables -A INPUT -p ${proto} --match multiport --dports ${intsS} --source ${subnetsS} -j ACCEPT"
    );

    startTCP = map (attr: mkAdd "tcp" attr.subnets attr.tcp) ports;
    startUDP = map (attr: mkAdd "udp" attr.subnets attr.udp) ports;

    # TODO: when stopping the firewall, systemd uses the old ports. So this is a two-phase process.
    # How to stop the old one and start the new one?
    mkDel = (
      proto: subnets: ints: let
        subnetsS = builtins.concatStringsSep "," subnets;
        intsS = builtins.concatStringsSep "," (map builtins.toString ints);
      in
        if builtins.length ints == 0
        then ""
        else "iptables -D INPUT -p ${proto} --match multiport --dports ${intsS} --source ${subnetsS} -j ACCEPT || :"
    );

    stopTCP = map (attr: mkDel "tcp" attr.subnets attr.tcp) ports;
    stopUDP = map (attr: mkDel "udp" attr.subnets attr.udp) ports;
  in {
    networking.firewall.extraCommands = lib.concatLines (startTCP ++ startUDP);
    networking.firewall.extraStopCommands = lib.concatLines (stopTCP ++ stopUDP);
  };
}

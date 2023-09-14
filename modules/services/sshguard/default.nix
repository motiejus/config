{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.sshguard = with lib.types; {
    enable = lib.mkOption {
      type = bool;
      default = false;
    };
  };

  config = lib.mkIf config.mj.services.sshguard.enable {
    services.sshguard = {
      enable = true;
      blocktime = 900;
      whitelist =
        ["192.168.0.0/16" myData.subnets.tailscale.cidr]
        ++ (lib.catAttrs "publicIP" (lib.attrValues myData.hosts));
    };
  };
}

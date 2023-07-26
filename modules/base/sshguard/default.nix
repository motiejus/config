{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.base.sshguard = with lib.types; {
    enable = lib.mkOption {
      type = bool;
      default = true;
    };
  };

  config = lib.mkIf config.mj.base.sshguard.enable {
    services.sshguard = {
      enable = true;
      blocktime = 900;
      whitelist = [
        "192.168.0.0/16"
        myData.tailscale_subnet.cidr
      ] ++ (lib.catAttrs "publicIP" (lib.attrValues myData.hosts));
    };
  };
}

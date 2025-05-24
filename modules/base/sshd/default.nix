{
  lib,
  config,
  myData,
  ...
}:
{
  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    programs.mosh.enable = true;
    programs.ssh = {
      knownHosts =
        let
          filtered = lib.filterAttrs (_key: value: lib.hasAttr "publicKey" value) myData.hosts;
          sshAttrs = lib.genAttrs [
            "extraHostNames"
            "publicKey"
          ] (_: null);
        in
        lib.mapAttrs (_name: builtins.intersectAttrs sshAttrs) filtered;
      extraConfig = ''
        Host git.jakstys.lt
          HostName fwminex.jakst.vpn
      '';
    };
  };
}

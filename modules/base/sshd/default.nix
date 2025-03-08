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
      extraConfig =
        ''
          Host git.jakstys.lt
            HostName ${myData.hosts."fwminex.jakst.vpn".jakstIP}

        ''
        + (lib.concatMapStringsSep "\n"
          (host: ''
            Host ${builtins.elemAt (lib.splitString "." host) 0}
              HostName ${myData.hosts.${host}.jakstIP}
          '')
          (
            builtins.attrNames (
              lib.filterAttrs (name: props: name != "fra1-b.jakst.vpn" && props ? jakstIP) myData.hosts
            )
          )
        );
    };
  };
}

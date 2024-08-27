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
          sshAttrs = lib.genAttrs [
            "extraHostNames"
            "publicKey"
          ] (_: null);
        in
        lib.mapAttrs (_name: builtins.intersectAttrs sshAttrs) myData.hosts;
      extraConfig =
        ''
          Host git.jakstys.lt
            HostName ${myData.hosts."fwminex.servers.jakst".jakstIP}
        ''
        + (lib.concatMapStringsSep "\n" (host: ''
          Host ${builtins.elemAt (lib.splitString "." host) 0}
            HostName ${myData.hosts.${host}.jakstIP}
        '') (builtins.attrNames (lib.filterAttrs (_: props: props ? jakstIP) myData.hosts)));
    };
  };
}

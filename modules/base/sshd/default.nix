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
    };
  };
}

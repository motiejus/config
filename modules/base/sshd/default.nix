{
  config,
  lib,
  myData,
  ...
}: {
  config = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    programs.mosh.enable = true;
    programs.ssh.knownHosts = let
      sshAttrs = lib.genAttrs ["extraHostNames" "publicKey"] (name: null);
    in
      lib.mapAttrs (name: cfg: builtins.intersectAttrs sshAttrs cfg) myData.hosts;
  };
}

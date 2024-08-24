{
  lib,
  config,
  pkgs,
  myData,
  ...
}:
{
  config = {
    services.spiped = {
      enable = true;
      decrypt = true;
      source = "*:8022";
      target = "127.0.0.1:22";
      keyFile = config.age.secrets.ssh8022.path;
    };
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
      extraConfig = ''
        Host dl.jakstys.lt
        ProxyCommand ${pkgs.spiped}/bin/spipe -t %h:8022 -k ${config.age.secrets.ssh8022.path}
      '';
    };
    networking.firewall.allowedTCPPorts = [ myData.ports.ssh8022 ];
  };
}

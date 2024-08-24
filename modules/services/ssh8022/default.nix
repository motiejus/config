{
  lib,
  config,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.ssh8022;
in
{
  options.mj.services.ssh8022 = {
    enable = lib.mkEnableOption "Enable ssh8022";
  };

  config = lib.mkIf cfg.enable {
    services.spiped = {
      enable = true;
      config = {
        ssh8022 = {
          decrypt = true;
          source = "*:8022";
          target = "127.0.0.1:22";
          keyfile = config.age.secrets.ssh8022.path;
        };
      };
    };
    programs.ssh.extraConfig = ''
      Host dl.jakstys.lt
      ProxyCommand ${pkgs.spiped}/bin/spipe -t %h:8022 -k ${config.age.secrets.ssh8022.path}
    '';
    networking.firewall.allowedTCPPorts = [ myData.ports.ssh8022 ];
  };
}

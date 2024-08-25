{
  lib,
  config,
  pkgs,
  myData,
  ...
}:
{
  options.mj.services.ssh8022 = with lib.types; {
    client = {
      enable = lib.mkEnableOption "Enable ssh8022 client";
      keyfile = lib.mkOption { type = str; };
    };
    server = {
      enable = lib.mkEnableOption "Enable ssh8022 server";
      keyfile = lib.mkOption { type = str; };
    };
  };

  config = lib.mkMerge [
    (
      let
        cfg = config.mj.services.ssh8022.client;
      in
      lib.mkIf cfg.enable {
        programs.ssh.extraConfig = ''
          Host dl.jakstys.lt
          ProxyCommand ${pkgs.spiped}/bin/spipe -t %h:8022 -k ${cfg.keyfile}
        '';
      }
    )
    (
      let
        cfg = config.mj.services.ssh8022.server;
      in
      lib.mkIf cfg.enable {
        services.spiped = {
          enable = true;
          config = {
            ssh8022 = {
              inherit (cfg) keyfile;
              decrypt = true;
              source = "[0.0.0.0]:8022";
              target = "127.0.0.1:22";
            };
          };
        };
        networking.firewall.allowedTCPPorts = [ myData.ports.ssh8022 ];
      }
    )
  ];
}

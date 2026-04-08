{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.ssh8022.client;
in
{
  options.mj.services.ssh8022.client = with lib.types; {
    enable = lib.mkEnableOption "Enable ssh8022 client";
    keyfile = lib.mkOption { type = str; };
  };

  config = lib.mkIf cfg.enable {
    programs.ssh.extraConfig = ''
      Host fra1-c.jakstys.lt jakstys.lt
        ProxyCommand ${pkgs.spiped}/bin/spipe -t %h:8022 -k ${cfg.keyfile}
    '';
  };
}

{
  lib,
  config,
  myData,
  ...
}:
let
  cfg = config.mj.services.ssh8022.server;
in
{
  options.mj.services.ssh8022.server = with lib.types; {
    enable = lib.mkEnableOption "Enable ssh8022 server";
    keyfile = lib.mkOption { type = str; };
    openGlobalFirewall = lib.mkOption {
      type = bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    services = {
      openssh.openFirewall = cfg.openGlobalFirewall;

      spiped = {
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
    };
    networking.firewall.allowedTCPPorts = [ myData.ports.ssh8022 ];
    systemd.services."spiped@ssh8022" = {
      wantedBy = [ "multi-user.target" ];
      overrideStrategy = "asDropin";
    };
  };
}

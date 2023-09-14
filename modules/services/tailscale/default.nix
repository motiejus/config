{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
  options.mj.services.tailscale = with lib.types; {
    enable = lib.mkEnableOption "Enable tailscale";
    # https://github.com/tailscale/tailscale/issues/1548
    silenceLogs = lib.mkOption {
      type = bool;
      default = false;
    };
  };

  config = with config.mj.services.tailscale;
    lib.mkIf enable {
      services.tailscale.enable = true;
      networking.firewall.checkReversePath = "loose"; # for tailscale
    }
    // lib.mkIf silenceLogs {
      systemd.services.tailscale.serviceConfig."StandardOutput" = "null";
    };
}

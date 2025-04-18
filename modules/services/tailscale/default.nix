{
  config,
  lib,
  myData,
  ...
}:
let
  cfg = config.mj.services.tailscale;
  inherit (lib)
    mkMerge
    types
    mkEnableOption
    mkOption
    mkIf
    ;
in
{
  options.mj.services.tailscale = with types; {
    enable = mkEnableOption "Enable tailscale";
    acceptDNS = mkOption {
      type = bool;
      default = true;
    };
    # https://github.com/tailscale/tailscale/issues/1548
    verboseLogs = mkOption {
      type = bool;
      default = false;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.tailscale = {
        enable = true;
        extraUpFlags = [
          "--operator=${config.mj.username}"
        ];
        extraSetFlags = [
          "--accept-dns=${if cfg.acceptDNS then "true" else "false"}"
          "--accept-routes=true"
        ];
      };
      networking.firewall.checkReversePath = "loose";
      networking.firewall.allowedUDPPorts = [ myData.ports.tailscale ];
    }
    (mkIf (!cfg.verboseLogs) { systemd.services.tailscaled.serviceConfig.StandardOutput = "null"; })
  ]);
}

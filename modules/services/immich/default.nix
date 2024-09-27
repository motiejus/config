{
  config,
  lib,
  pkgs,
  myData,
  nixpkgs-unstable,
  ...
}:
let
  cfg = config.mj.services.immich;
in
{
  options.mj.services.immich = with lib.types; {
    enable = lib.mkEnableOption "enable immich";
    paths = lib.mkOption { type = attrsOf str; };
  };

  imports = [ "${nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix" ];

  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      port = myData.ports.immich;
      package = pkgs.pkgs-unstable.immich;
      mediaLocation = "/var/cache/immich/userdata";
    };

    mj.services.friendlyport.ports = [
      {
        subnets = [ myData.subnets.tailscale.cidr ];
        tcp = [ myData.ports.immich ];
      }
    ];

    systemd = {
      tmpfiles.rules = [ "d /var/cache/immich/userdata 0700 immich immich -" ];
      services.immich.serviceConfig = {
        ProtectHome = lib.mkForce "tmpfs";
        CacheDirectory = "immich";
        BindPaths = lib.mapAttrsToList (
          name: srcpath: "${srcpath}:/var/cache/immich/userdata/${name}"
        ) cfg.paths;
      };
    };

  };

}

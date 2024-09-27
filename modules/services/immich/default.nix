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
      port = myData.ports.immich-server;
      package = pkgs.pkgs-unstable.immich;
    };

    services.caddy.virtualHosts."photos2.jakstys.lt:80".extraConfig = ''
      @denied not remote_ip ${myData.subnets.tailscale.cidr}
      reverse_proxy localhost:${toString myData.ports.immich-server}
    '';

    #systemd = {
    #  #tmpfiles.rules = [ "d /var/cache/immich/userdata 0700 immich immich -" ];
    #  services.immich-server.serviceConfig = {
    #    #ProtectHome = lib.mkForce "tmpfs";
    #    #CacheDirectory = "immich";
    #    #BindPaths = lib.mapAttrsToList (
    #    #  name: srcpath: "${srcpath}:/var/cache/immich/userdata/${name}"
    #    #) cfg.paths;
    #  };
    #};

  };

}

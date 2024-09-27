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
    bindPaths = lib.mkOption { type = attrsOf str; };
    bindAsUser = lib.mkOption { type = str; };
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

    systemd = {
      tmpfiles.rules = [
        "d /var/cache/immich/userdata 0700 immich immich -"
      ] ++ lib.mapAttrsToList (name: _: "/var/cache/immich/userdata/${name}") cfg.bindPaths;
      services.immich-server.serviceConfig = {
        ExecStartPre = lib.mapAttrsToList (
          name: srcpath:
          "+${pkgs.bindfs}/bin/bindfs -u ${cfg.bindAsUser} ${srcpath} /var/cache/immich/userdata/${name}"
        ) cfg.bindPaths;
      };
    };

  };

}

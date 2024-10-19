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
  immich-package = pkgs.pkgs-unstable.immich;
  immich-user = config.services.immich.user;
  immich-group = config.services.immich.group;
  startScript = pkgs.writeShellApplication {
    name = "immich-mj";
    runtimeInputs = with pkgs; [
      bindfs
      util-linux
    ];
    text = ''
      set -x
      ${lib.concatMapStringsSep "\n"
        (name: ''
          mkdir /data/${name}
          bindfs -u ${immich-user} -g ${immich-group} /var/run/immich/bind-paths/${name} /data/${name}'')
        (lib.attrNames cfg.bindPaths)
      }
      exec setpriv \
        --ruid ${immich-user} \
        --inh-caps -all \
        ${lib.getExe immich-package}
    '';
  };
in
{
  options.mj.services.immich = with lib.types; {
    enable = lib.mkEnableOption "enable immich";
    bindPaths = lib.mkOption { type = attrsOf str; };
  };

  imports = [ "${nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix" ];

  config = lib.mkIf cfg.enable {

    services.immich = {
      package = immich-package;
      enable = true;
      port = myData.ports.immich-server;

      # TODO: remove the whole block 24.11: redis should listen on the unix socket
      # if immich can't find/connect to redis, it will fail on boot, so it's
      # safe to experiment.
      redis = {
        enable = true;
        host = "127.0.0.1";
        port = 6379;
      };
    };

    services.caddy.virtualHosts."photos.jakstys.lt:80".extraConfig = ''
      @denied not remote_ip ${myData.subnets.tailscale.cidr}
      reverse_proxy localhost:${toString myData.ports.immich-server}
    '';

    systemd = {
      tmpfiles.rules = [ "d /data 0755 root root -" ];
      services.immich-server.serviceConfig = {
        RuntimeDirectory = "immich";
        TemporaryFileSystem = "/data";
        BindPaths = lib.mapAttrsToList (
          name: srcpath: "${srcpath}:/var/run/immich/bind-paths/${name}"
        ) cfg.bindPaths;
        PrivateDevices = lib.mkForce false; # /dev/fuse
        CapabilityBoundingSet = lib.mkForce "~";
        ExecStart = lib.mkForce ("!" + (lib.getExe startScript));
        PrivateUsers = lib.mkForce false; # bindfs fails otherwise
      };
    };

  };

}

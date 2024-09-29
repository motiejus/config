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
          bindfs -u ${immich-user} /var/run/immich/bind-paths/${name} /data/${name}'')
        (lib.attrNames cfg.bindPaths)
      }
      exec setpriv \
        --ruid ${immich-user} \
        --inh-caps -sys_admin,-setuid,-setgid \
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
    };

    services.caddy.virtualHosts."photos.jakstys.lt:80".extraConfig = ''
      @denied not remote_ip ${myData.subnets.tailscale.cidr}
      reverse_proxy localhost:${toString myData.ports.immich-server}
    '';

    systemd = {
      tmpfiles.rules = [
        "d /data 0755 root root -"
        "d /var/run/immich/bind-paths 0755 ${immich-user} ${immich-group} -"
      ];
      services.immich-server.serviceConfig = {
        RuntimeDirectory = "immich";
        TemporaryFileSystem = "/data";
        BindPaths = lib.mapAttrsToList (
          name: srcpath: "${srcpath}:/var/run/immich/bind-paths/${name}"
        ) cfg.bindPaths;
        PrivateDevices = lib.mkForce false; # /dev/fuse
        CapabilityBoundingSet = lib.mkForce "CAP_SYS_ADMIN | CAP_SETUID | CAP_SETGID";
        ExecStart = lib.mkForce ("!" + (lib.getExe startScript));
        PrivateUsers = lib.mkForce false; # bindfs fails otherwise
      };
    };

  };

}

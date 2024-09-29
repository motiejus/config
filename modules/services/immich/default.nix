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
  startScript = pkgs.writeShellApplication {
    name = "immich-mj";
    runtimeInputs = with pkgs; [
      sudo
      bindfs
      util-linux
    ];
    text = ''
      ${lib.concatLines (
        lib.mapAttrsToList (name: srcpath: ''
          #mkdir /data/${name}
          #bindfs -u ${cfg.bindAsUser} ${srcpath} /data/${name}
        '') cfg.bindPaths
      )}
      #exec sudo -u ${config.services.immich.user} -- ${lib.getExe immich-package}
      exec ${lib.getExe immich-package}
    '';
  };
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
      package = immich-package;
      enable = true;
      port = myData.ports.immich-server;
    };

    services.caddy.virtualHosts."photos2.jakstys.lt:80".extraConfig = ''
      @denied not remote_ip ${myData.subnets.tailscale.cidr}
      reverse_proxy localhost:${toString myData.ports.immich-server}
    '';

    systemd = {
      tmpfiles.rules = [ "d /data 0755 root root -" ];
      services.immich-server.serviceConfig = {
        TemporaryFileSystem = "/data";
        PrivateDevices = lib.mkForce false; # /dev/fuse
        ProtectHome = lib.mkForce false; # binding /home/motiejus

        # testing
        PrivateMounts = lib.mkForce false;

        ExecStart = lib.mkForce ("!" + (lib.getExe startScript));
      };
    };

  };

}

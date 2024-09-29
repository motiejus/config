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
    runtimeInputs = with pkgs; [ bindfs ];
    text = ''
      set -x
      ${lib.concatLines (
        map (name: ''
          mkdir /data/${name}
          bindfs -u ${cfg.bindAsUser} /var/cache/immich/bind-paths/${name} /data/${name}
        '') (lib.attrNames cfg.bindPaths)
      )}
      exec ${config.security.wrapperDir}/doas -u ${immich-user} ${lib.getExe immich-package}
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
    security.doas.enable = true;
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
      tmpfiles.rules = [
        "d /data 0755 root root -"
        "d /var/cache/immich/bind-paths 0755 ${immich-user} ${immich-group} -"
      ];
      services.immich-server.serviceConfig = {
        RuntimeDirectory = "immich";
        TemporaryFileSystem = "/data";
        BindPaths = lib.mapAttrsToList (
          name: srcpath: "${srcpath}:/var/cache/immich/bind-paths/${name}"
        ) cfg.bindPaths;
        PrivateDevices = lib.mkForce false; # /dev/fuse
        ProtectHome = lib.mkForce false; # binding /home/motiejus
        CapabilityBoundingSet = lib.mkForce "CAP_SYS_ADMIN | CAP_SETUID | CAP_SETGID";

        # testing
        ExecStart = lib.mkForce ("!" + (lib.getExe startScript));
        NoNewPrivileges = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        PrivateMounts = lib.mkForce false;
        ProtectClock = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectHostname = lib.mkForce false;
        ProtectKernelLogs = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        RestrictNamespaces = lib.mkForce false;
        RestrictRealtime = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
      };
    };

  };

}

{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.tailscale-ssh;

  vpnDomain = ".jakst.vpn";

  vpnHosts = lib.filterAttrs (name: _: lib.hasSuffix vpnDomain name) myData.hosts;

  hostConfigs = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      fqdn: _:
      let
        shortName = lib.removeSuffix vpnDomain fqdn;
      in
      ''
        Host ${shortName}
          User motiejus
          ProxyCommand bash -c 'exec nc $(${pkgs.tailscale}/bin/tailscale ip -4 ${shortName}) %p'
      ''
    ) vpnHosts
  );
in
{
  options.mj.services.tailscale-ssh = {
    enable = lib.mkEnableOption "SSH via Tailscale IP lookup for VPN hosts";
  };

  config = lib.mkIf cfg.enable {
    programs.ssh.extraConfig = hostConfigs;
  };
}

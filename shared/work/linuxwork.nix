{ config, pkgs, ... }:
{
  imports = [ ./. ];

  networking = {
    hosts."127.0.0.1" = [
      "go"
      "go."
    ];
    firewall.allowedTCPPorts = [ 80 ];
  };

  mj.base.users = {
    email = null;
  };

  environment.systemPackages = with pkgs; [
    chronoctl
    (pkgs.go-raceless.override { inherit (pkgs.pkgs-unstable) go; })
  ];

  home-manager.users.${config.mj.username}.programs.chromium.extensions = [
    { id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"; } # 1password
    { id = "mdkgfdijbhbcbajcdlebbodoppgnmhab"; } # GoLinks
    { id = "kgjfgplpablkjnlkjmjdecgdpfankdle"; } # Zoom
  ];
}

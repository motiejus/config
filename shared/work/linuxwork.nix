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
    wrapGo = true;
  };

  environment.systemPackages = with pkgs; [
    chronoctl
  ];

  home-manager.users.${config.mj.username}.programs.chromium.extensions = [
    { id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"; } # 1password
    { id = "mdkgfdijbhbcbajcdlebbodoppgnmhab"; } # GoLinks
    { id = "kgjfgplpablkjnlkjmjdecgdpfankdle"; } # Zoom
  ];
}

{ pkgs, ... }:
{
  imports = [
    ../../modules/macbase
    ../../modules/profiles/basedesktop
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;

  mj = {
    stateVersion = "25.11";
    timeZone = "UTC";
    username = "motiejus";
    base.mac.devTools = true;
  };

  home-manager.users.motiejus.programs.ghostty.package = pkgs.ghostty-bin;
}

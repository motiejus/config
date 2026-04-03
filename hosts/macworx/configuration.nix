{ config, pkgs, ... }:
{
  imports = [
    ../../modules/macbase
    ../../modules/profiles/basedesktop
    ../../shared/work/macwork.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;

  mj = {
    stateVersion = "25.11";
    timeZone = "GMT";
    username = "mjakstys";
    base.mac.devTools = true;
  };

  system.keyboard = {
    enableKeyMapping = true;
    nonUS.remapTilde = true;
  };

  home-manager.users.${config.mj.username}.programs.ghostty.package = pkgs.ghostty-bin;
}

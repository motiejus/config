{ config, pkgs, ... }:
{
  imports = [
    ../../modules/macbase
    ../../modules/profiles/basedesktop
    ../../shared/work/macwork.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system = {
    stateVersion = 6;

    defaults.CustomUserPreferences."com.apple.HIToolbox" = {
      AppleEnabledInputSources = [
        {
          InputSourceKind = "Keyboard Layout";
          "KeyboardLayout ID" = 0;
          "KeyboardLayout Name" = "U.S.";
        }
        {
          InputSourceKind = "Keyboard Layout";
          "KeyboardLayout ID" = 30;
          "KeyboardLayout Name" = "Lithuanian";
        }
      ];
    };
  };

  mj = {
    stateVersion = "25.11";
    timeZone = "GMT";
    username = "mjakstys";
    base.mac.devTools = true;
  };

  home-manager.users.${config.mj.username}.programs.ghostty.package = pkgs.ghostty-bin;
}

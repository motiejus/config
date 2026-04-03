{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj;
in
{
  imports = [ ../base ];
  options.mj.base.mac = with lib.types; {
    devTools = lib.mkOption {
      type = bool;
      default = false;
    };
    wrapGo = lib.mkOption {
      type = bool;
      default = false;
    };
    email = lib.mkOption {
      type = nullOr str;
      default = null;
    };
  };

  config = {
    nix.gc.interval = {
      Weekday = 0;
      Hour = 2;
      Minute = 0;
    };

    users.users.${cfg.username}.home = "/Users/${cfg.username}";

    system = {
      primaryUser = cfg.username;
      keyboard = {
        enableKeyMapping = true;
        nonUS.remapTilde = true;
      };

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

    programs.bash.enable = true;
    programs.zsh.enable = lib.mkForce false;
    environment.shells = [ pkgs.bash ];

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bk";
      users.${cfg.username} =
        { pkgs, ... }:
        import ../../shared/home {
          inherit lib pkgs;
          inherit (cfg) stateVersion username;
          inherit (cfg.base.mac) devTools wrapGo email;
          homeDirectory = "/Users/${cfg.username}";
        };
    };
  };
}

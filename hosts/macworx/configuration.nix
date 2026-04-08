{ config, pkgs, ... }:
let
  tealWallpaper =
    pkgs.runCommand "teal-wallpaper.png"
      {
        nativeBuildInputs = [ pkgs.imagemagick ];
      }
      ''
        magick -size 3840x2160 canvas:"#008080" $out
      '';
in
{
  imports = [
    ../../modules/macbase
    ../../modules/profiles/basedesktop
    ../../modules/profiles/terminal
    ../../modules/profiles/devtools
    ../../modules/profiles/work/mac.nix
    # TODO: enable ssh8022 client once key is provisioned
    #../../modules/services/ssh8022/client.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system = {
    stateVersion = 6;
  };

  mj = {
    stateVersion = "25.11";
    timeZone = "GMT";
    username = "mjakstys";
  };

  system.defaults.dock.show-recents = false;
  system.defaults.dock.persistent-others = [
    { folder = "/Users/${config.mj.username}/Downloads"; }
  ];
  system.defaults.dock.persistent-apps = [
    "/Users/${config.mj.username}/Applications/Home Manager Apps/Ghostty.app"
    "/Applications/Prisma Access Browser.app"
    "/Users/${config.mj.username}/Applications/Home Manager Apps/Firefox.app"
    "/Applications/Self Service.app"
    "/System/Library/CoreServices/Finder.app"
    "/System/Applications/System Settings.app"
  ];

  system.activationScripts.postActivation.text = ''
    osascript -e 'tell application "System Events" to tell every desktop to set picture to "${tealWallpaper}"'
  '';

  environment.systemPackages = [
    pkgs.autoraise
    pkgs.syncthing-macos
    pkgs.tailscale
  ];

  launchd.daemons.tailscaled = {
    command = "${pkgs.tailscale}/bin/tailscaled";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
    };
  };

  launchd.user.agents.autoraise = {
    command = "${pkgs.autoraise}/bin/autoraise";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
    };
  };

  home-manager.users.${config.mj.username}.programs.ghostty.package = pkgs.ghostty-bin;
}

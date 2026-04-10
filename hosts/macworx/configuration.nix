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
    ../../modules/services/ssh8022/client.nix
    ../../modules/services/tailscale-ssh
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

  age.secrets.ssh8022-client = {
    file = ../../secrets/ssh8022.age;
    mode = "444";
  };

  mj.services.tailscale-ssh.enable = true;

  # git.jakstys.lt is fwminex; route via tailscale (no MagicDNS)
  programs.ssh.extraConfig = ''
    Host git.jakstys.lt
      ProxyCommand bash -c 'exec nc $(${pkgs.tailscale}/bin/tailscale ip -4 fwminex) %p'
  '';

  mj.services.ssh8022.client = {
    enable = true;
    keyfile = config.age.secrets.ssh8022-client.path;
  };

  system.activationScripts.postActivation.text = ''
    osascript -e 'tell application "System Events" to tell every desktop to set picture to "${tealWallpaper}"'

    # Disable screensaver
    defaults -currentHost write com.apple.screensaver idleTime -int 0
  '';

  environment.systemPackages = [
    pkgs.autoraise
    pkgs.syncthing-macos
    pkgs.pkgs-unstable.colima
    pkgs.pkgs-unstable.docker-client
    pkgs.tailscale
    # RustDesk client: install .dmg from rustdesk.com (nix doesn't build on darwin)
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

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

    # Disable automatic timezone
    defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false

    # Disable screensaver
    defaults -currentHost write com.apple.screensaver idleTime -int 0

    # Install xscreensaver .saver bundles
    mkdir -p "/Users/${config.mj.username}/Library/Screen Savers"
    ln -sf ${pkgs.xscreensaver-mac}/Library/Screen\ Savers/*.saver "/Users/${config.mj.username}/Library/Screen Savers/"
  '';

  environment.systemPackages = with pkgs; [
    autoraise
    tailscale
    syncthing-macos
    pkgs-unstable.colima
    pkgs-unstable.docker-client
    # TODO(26.05): switch to pkgs.xquartz
    pkgs-unstable.xquartz
    pkgs.xscreensaver-mac
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

  home-manager.users.${config.mj.username} = {
    programs.ghostty.package = pkgs.ghostty-bin;

    home.file.".colima/_templates/default.yaml".text = ''
      cpu: 2
      memory: 4
      disk: 100
      arch: aarch64
      runtime: docker
      vmType: vz
      mountType: virtiofs
      mountInotify: true
      mounts:
        - location: /Users/mjakstys
          writable: true
        - location: /var/folders
          writable: true
    '';
  };
}

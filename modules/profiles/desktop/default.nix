{
  config,
  lib,
  pkgs,
  ...
}: {
  config = {
    services.udev.packages = [pkgs.yubikey-personalization];

    programs = {
      #firefox = {
      #  enable = true;
      #  languagePacks = ["en-US" "lt" "de"];
      #};
    };

    mj.base.users.passwd.motiejus.extraGroups = ["networkmanager"];

    services = {
      pcscd.enable = true;
      xserver = {
        enable = true;
        desktopManager.xfce.enable = true;
        displayManager.lightdm.enable = true;
      };

      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
    };

    security.rtkit.enable = true;

    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      vlc
      gimp
      qgis
      josm
      joplin
      yt-dlp
      pandoc
      evince
      rtorrent
      gpicview
      signal-desktop
      element-desktop

      gnome.nautilus
      gnome.gnome-calculator
      gnome.gnome-calendar

      pavucontrol
      libreoffice-qt
      hunspell
      hunspellDicts.en_US
    ];

    home-manager.users.motiejus = {pkgs, ...}: {
      programs.firefox = {
        enable = true;
        #package = pkgs.firefox-devedition;
        profiles = {
          xdefault = {
            isDefault = true;
            search.default = "DuckDuckGo";
            settings = {
              "browser.contentblocking.category" = "strict";
              "layout.css.prefers-color-scheme.content-override" = 0;
            };
            extensions = with pkgs.nur.repos.rycee.firefox-addons; [
              ublock-origin
              joplin-web-clipper
            ];
          };
        };
      };
    };
  };
}

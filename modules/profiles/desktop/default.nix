{
  config,
  lib,
  pkgs,
  ...
}: {
  config = {
    services.udev.packages = [pkgs.yubikey-personalization];

    programs.firefox.enable = true;

    mj.base.users.passwd.motiejus.extraGroups = ["networkmanager"];

    services = {
      pcscd.enable = true;
      xserver = {
        enable = true;
        layout = "us,lt";
        xkbOptions = "grp:alt_shift_toggle";

        displayManager = {
          sddm.enable = true;
          defaultSession = "none+awesome";
        };

        windowManager.awesome = {
          enable = true;
        };

        desktopManager.xfce.enable = true;
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
      pdftk
      yt-dlp
      arandr
      pandoc
      evince
      rtorrent
      gpicview
      rox-filer
      pavucontrol
      graphicsmagick
      joplin-desktop
      signal-desktop
      element-desktop

      gnome.nautilus
      gnome.gnome-calculator
      gnome.gnome-calendar

      libreoffice-qt
      hunspell
      hunspellDicts.en_US
    ];

    home-manager.users.motiejus = {pkgs, ...}: {
      services.gpg-agent = {
        enable = true;
        enableSshSupport = true;
      };

      programs.firefox = {
        enable = true;
        profiles = {
          xdefault = {
            isDefault = true;
            search.default = "DuckDuckGo";
            settings = {
              "browser.contentblocking.category" = "strict";
              "layout.css.prefers-color-scheme.content-override" = 0;
              "browser.aboutConfig.showWarning" = false;
              "signon.rememberSignons" = false;
              "signon.management.page.breach-alerts.enabled" = false;
            };
            extensions = with pkgs.nur.repos.rycee.firefox-addons; [
              bitwarden
              ublock-origin
              joplin-web-clipper
              multi-account-containers
            ];
          };
        };
      };
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}: {
  config = {
    services.udev.packages = [pkgs.yubikey-personalization];

    programs.firefox.enable = true;

    mj.base.users.passwd.motiejus.extraGroups = ["adbusers" "networkmanager"];

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

      printing.enable = true;
    };

    programs = {
      slock.enable = true;
      nm-applet.enable = true;
      adb.enable = true;
    };

    security.rtkit.enable = true;

    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      vlc
      gimp
      qgis
      josm
      xclip
      pdftk
      yt-dlp
      arandr
      pandoc
      evince
      calibre
      chromium
      hunspell
      tigervnc
      rtorrent
      bsdgames
      xss-lock
      qpwgraph # for pipewire
      gpicview
      rox-filer
      winetricks
      python3Full
      libva-utils # intel video tests
      pavucontrol
      google-chrome
      aspellDicts.en
      aspellDicts.lt
      libreoffice-qt
      graphicsmagick
      joplin-desktop
      signal-desktop
      element-desktop
      wineWowPackages.full
      hunspellDicts.en_US
      python310Packages.ipython
      samsung-unified-linux-driver

      gnome.nautilus
      gnome.gnome-calculator
      gnome.gnome-calendar

      (texlive.combine {
        inherit
          (texlive)
          scheme-medium
          dvisvgm
          dvipng
          wrapfig
          amsmath
          ulem
          hyperref
          capt-of
          lithuanian
          hyphen-lithuanian
          ;
      })
    ];

    home-manager.users.motiejus = {pkgs, ...}: {
      services.gpg-agent = {
        enable = true;
        enableSshSupport = true;
      };

      programs.autorandr = {
        enable = true;
      };

      programs.firefox = {
        enable = true;
        profiles = {
          xdefault = {
            isDefault = true;
            #search.default = "DuckDuckGo";
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

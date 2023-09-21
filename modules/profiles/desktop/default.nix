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
      acpid.enable = true;
      pcscd.enable = true;
      printing.enable = true;
      openssh.settings.X11Forwarding = true;

      # TODO post-23.11
      #logind.powerKey = "suspend";
      #logind.powerKeyLongPress = "poweroff";
      logind.extraConfig = ''
        HandlePowerKey=suspend
        HandlePowerKeyLongPress=poweroff
      '';

      xserver = {
        enable = true;
        layout = "us,lt";
        xkbOptions = "grp:alt_shift_toggle";

        desktopManager.xfce.enable = true;
        windowManager.awesome.enable = true;

        displayManager = {
          sddm.enable = true;
          defaultSession = "none+awesome";
          autoLogin = {
            enable = true;
            user = "motiejus";
          };
        };
      };

      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
    };

    programs = {
      adb.enable = true;
      slock.enable = true;
      nm-applet.enable = true;
      command-not-found.enable = false;
    };

    virtualisation.podman = {
      enable = true;
      extraPackages = [pkgs.zfs];
    };

    security.rtkit.enable = true;

    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      iw
      vlc
      acpi
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
      distrobox
      borgbackup
      efibootmgr
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
      python3Packages.ipython
      samsung-unified-linux-driver

      gnome.nautilus
      gnome.gnome-calculator
      gnome.gnome-calendar

      xorg.xev

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
      xdg.configFile."awesome/rc.lua".source = ./rc.lua;

      programs.firefox = {
        enable = true;
        profiles = {
          xdefault = {
            isDefault = true;
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

      services.pasystray = {
        enable = true;
        extraOptions = ["--key-grabbing" "--notify=all"];
      };

      services.gpg-agent = {
        enable = true;
        enableSshSupport = true;
      };

      services.screen-locker = {
        enable = true;
        xautolock.enable = false;
        lockCmd = ''${pkgs.bash}/bin/bash -c "${pkgs.coreutils}/bin/sleep 0.2; ${pkgs.xorg.xset}/bin/xset dpms force off; /run/wrappers/bin/slock"'';
      };
    };
  };
}

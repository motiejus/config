{
  config,
  pkgs,
  ...
}: {
  config = {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    programs = {
      firefox.enable = true;
      wireshark.enable = true;
    };

    mj.base.users.passwd.motiejus.extraGroups = ["adbusers" "networkmanager" "wireshark"];

    services = {
      fwupd.enable = true;
      blueman.enable = true;
      udev.packages = [pkgs.yubikey-personalization];
      acpid.enable = true;
      pcscd.enable = true;
      printing = {
        enable = true;
        drivers = [pkgs.samsung-unified-linux-driver_4_01_17];
      };
      openssh.settings.X11Forwarding = true;

      logind.powerKey = "suspend";
      logind.powerKeyLongPress = "poweroff";

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

      gnome.gnome-keyring.enable = true;
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

    # wip put clight-gui to nixpkgs
    #services.geoclue2 = {
    #  enable = true;
    #  enableWifi = true;
    #};
    #location.provider = "geoclue2";

    documentation = {
      dev.enable = true;
      doc.enable = true;
      info.enable = true;
      man = {
        enable = true;
        man-db.enable = false;
        mandoc.enable = true;
      };
    };

    environment.systemPackages = with pkgs; [
      iw
      vlc
      i7z
      acpi
      gimp
      qgis
      josm
      qemu
      xclip
      pdftk
      x11vnc
      yt-dlp
      ffmpeg
      tinycc
      scrcpy
      arandr
      pandoc
      evince
      scribus
      gnumake
      calibre
      librsvg
      neomutt
      inkscape
      chromium
      hunspell
      tigervnc
      rtorrent
      bsdgames
      xss-lock
      qpwgraph # for pipewire
      audacity
      powertop
      gpicview
      imapsync
      trayscale
      # TODO why doesn't 'programs.wireshark.enable = true' install the binary?
      wireshark
      man-pages
      rox-filer
      distrobox
      miniupnpc
      evolution
      obs-studio
      shellcheck
      borgbackup
      efibootmgr
      winetricks
      virtualenv
      python3Full
      libva-utils # intel video tests
      pavucontrol
      openshot-qt
      squashfsTools
      google-chrome
      aspellDicts.en
      aspellDicts.lt
      libreoffice-qt
      graphicsmagick
      joplin-desktop
      signal-desktop
      element-desktop
      netsurf-browser
      man-pages-posix
      geoipWithDatabase
      wineWowPackages.full
      hunspellDicts.en_US
      python3Packages.ipython
      samsung-unified-linux-driver

      lld
      llvm
      llvm-manpages
      clang-manpages
      gcc_latest

      gnome.cheese
      gnome.nautilus
      gnome.gnome-calculator
      gnome.gnome-calendar

      xorg.xev
      xorg.xeyes

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

    # https://discourse.nixos.org/t/nixos-rebuild-switch-upgrade-networkmanager-wait-online-service-failure/30746
    systemd.services.NetworkManager-wait-online.enable = false;

    home-manager.users.motiejus = {
      pkgs,
      config,
      ...
    }: {
      imports = [./plasma.nix];
      xdg.configFile."awesome/rc.lua".source = ./rc.lua;

      services = {
        cbatticon.enable = true;
        blueman-applet.enable = true;

        syncthing.tray = {
          enable = true;
          #extraOptions = ["--wait"];
        };

        pasystray = {
          enable = true;
          extraOptions = ["--key-grabbing" "--notify=all"];
        };

        gpg-agent = {
          enable = true;
          enableSshSupport = true;
        };

        screen-locker = {
          enable = true;
          xautolock.enable = false;
          lockCmd = ''${pkgs.bash}/bin/bash -c "${pkgs.coreutils}/bin/sleep 0.2; ${pkgs.xorg.xset}/bin/xset dpms force off; /run/wrappers/bin/slock"'';
        };
      };

      # https://github.com/nix-community/home-manager/issues/2064
      systemd.user.targets.tray = {
        Unit = {
          Description = "Home Manager System Tray";
          Requires = ["graphical-session-pre.target"];
        };
      };

      # thanks K900
      gtk = {
        enable = true;
        theme = {
          package = pkgs.plasma5Packages.breeze-gtk;
          name = "Breeze";
        };
        cursorTheme = {
          package = pkgs.plasma5Packages.breeze-icons;
          name = "Breeze_Snow";
        };
        iconTheme = {
          package = pkgs.papirus-icon-theme;
          name = "Papirus-Dark";
        };
        gtk2 = {
          configLocation = "${config.xdg.configHome}/gtk-2.0/gtkrc";
          extraConfig = ''
            gtk-alternative-button-order = 1
          '';
        };
        gtk3.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-decoration-layout = "icon:minimize,maximize,close";
        };
        gtk4.extraConfig = {
          gtk-application-prefer-dark-theme = true;
          gtk-decoration-layout = "icon:minimize,maximize,close";
        };
      };

      mj.plasma.kconfig = {
        kdeglobals = {
          General.ColorScheme = "ArcDark";
          Icons.Theme = "Papirus-Dark";
          KDE.widgetStyle = "Breeze";
        };
        plasmarc.Theme.name = "Arc-Dark";
        kscreenlockerrc.Greeter = {
          Theme = "com.github.varlesh.arc-dark";
        };
        ksplashrc.KSplash = {
          Engine = "KSplashQML";
          Theme = "com.github.varlesh.arc-dark";
        };
        kwinrc."org.kde.kdecoration2" = {
          library = "org.kde.kwin.aurorae";
          theme = "__aurorae__svg__Arc-Dark";
        };
        kcminputrc.Mouse.cursorTheme = "Breeze_Snow";
        # don't mess with GTK settings
        kded5rc."Module-gtkconfig".autoload = false;
      };
    };
  };
}

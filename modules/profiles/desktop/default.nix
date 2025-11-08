{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (config.mj) username;
  firefox =
    if (pkgs.stdenv.hostPlatform.system == "x86_64-linux") then pkgs.firefox-bin else pkgs.firefox;
  brightness = pkgs.writeShellApplication {
    name = "brightness";
    text = builtins.readFile ./brightness;
  };
  open = pkgs.writeShellApplication {
    name = "open";
    text = ''exec ${pkgs.xdg-utils}/bin/xdg-open "$@"'';
  };
in
{
  imports = [
    ../physical
  ];
  config = {
    boot = {
      kernelModules = [ "kvm-intel" ];
    };

    hardware = {
      bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
    };

    systemd.slices."docker-low" = {
      sliceConfig = {
        CPUWeight = 1;
        IOWeight = 1;
      };
    };

    programs = {
      firefox = {
        enable = true;
        package = firefox;
      };
      wireshark = {
        enable = true;
        package = pkgs.wireshark-qt;
      };
    };

    mj.services.printing.enable = true;

    mj.base.users.user.extraGroups = [
      "adbusers"
      "networkmanager"
      "wireshark"
      "docker"
    ];

    services = {
      blueman.enable = true;
      udev.packages = [ pkgs.yubikey-personalization ];
      gnome.gnome-keyring.enable = true;
      openssh.settings.X11Forwarding = true;

      pulseaudio = {
        enable = true;
        package = pkgs.pulseaudioFull;
      };

      logind = {
        powerKey = "suspend";
        powerKeyLongPress = "poweroff";
        lidSwitchExternalPower = "ignore";
      };

      avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };

      xserver = {
        enable = true;
        xkb = {
          layout = "us,lt";
          options = "grp:alt_shift_toggle";
        };

        desktopManager.xfce.enable = true;
        windowManager.awesome.enable = true;
        displayManager.lightdm.enable = true;
      };

      displayManager = {
        defaultSession = lib.mkDefault "none+awesome";
        autoLogin = {
          enable = true;
          user = username;
        };
      };

      pipewire.enable = false;

    };

    programs = {
      adb.enable = true;
      slock.enable = true;
      nm-applet.enable = true;
      command-not-found.enable = false;
    };

    security.rtkit.enable = true;

    networking.networkmanager.enable = true;

    # wip put clight-gui to nixpkgs
    #services.geoclue2 = {
    #  enable = true;
    #  enableWifi = true;
    #};
    #location.provider = "geoclue2";

    virtualisation.docker = {
      enable = true;
      # https://github.com/docker/buildx/issues/1459
      #daemon.settings.dns = [ "100.100.100.100" ];
      daemon.settings = {
        storage-driver = "btrfs";
        registry-mirrors = [ "https://mirror.gcr.io" ];

        exec-opts = [ "native.cgroupdriver=systemd" ];
        cgroup-parent = "docker-low.slice";
      };
    };

    fonts.packages = with pkgs; [
      xkcd-font
    ];

    environment.systemPackages = with pkgs; [
      # packages defined here
      open
      nicer
      tmuxbash
      brightness

      f3 # flight-flash-fraud
      gdb
      ntp
      vlc
      sox
      mpv
      imv # image viewer
      gimp
      qemu
      zlib
      xclip
      pdftk
      scrot
      tracy
      mb2md # mailbox2maildir
      cmake
      typst
      sioyek
      (kazam.override {
        python3Packages = pkgs.python311Packages;
      }) # alternative to gtk-recordMyDesktop
      x11vnc
      yt-dlp
      ffmpeg
      tinycc
      scrcpy
      cheese
      arandr
      pandoc
      evince
      ioping
      motion
      gthumb
      calibre
      gparted
      glabels-qt
      scribus
      gnumake
      libwebp
      librsvg
      picocom
      libheif
      csvkit
      mplayer
      tcpflow
      nautilus
      smplayer
      inkscape
      hunspell
      tigervnc
      bsdgames
      pstoedit
      xss-lock
      audacity
      colordiff
      trayscale
      espeak-ng
      man-pages
      rox-filer
      miniupnpc
      v4l-utils
      #nerdfonts
      winetricks
      shellcheck
      virtualenv
      imagemagick
      #ventoy-full
      ghostscript
      pavucontrol
      photocollage
      libqalculate # qalc
      qalculate-qt # qalculate
      google-chrome
      wirelesstools
      poppler_utils
      squashfsTools
      joplin-desktop
      aspellDicts.en
      aspellDicts.lt
      libreoffice-qt
      graphicsmagick
      magic-wormhole
      signal-desktop
      gnome-calendar
      element-desktop
      netsurf-browser
      man-pages-posix
      gnome-calculator
      libsForQt5.okular
      nvtopPackages.amd
      age-plugin-yubikey
      nvtopPackages.intel
      hunspellDicts.en_US
      samsung-unified-linux-driver

      xdotool
      xorg.xev
      xorg.xeyes
      xorg.lndir
      xorg.xinit

      (python3.withPackages (
        ps: with ps; [
          numpy
          pyyaml
          ipython
          matplotlib
        ]
      ))

    ];

    # https://discourse.nixos.org/t/nixos-rebuild-switch-upgrade-networkmanager-wait-online-service-failure/30746
    systemd.services.NetworkManager-wait-online.enable = false;

    home-manager.users.${username} =
      { pkgs, config, ... }:
      {
        imports = [ ./plasma.nix ];
        xdg.configFile = {
          "gdb/gdbinit".text = ''
            set style address foreground yellow
            set style function foreground cyan
            set style string foreground magenta
          '';
        };

        programs = {
          ghostty = {
            enable = true;
            installVimSyntax = true;
            enableBashIntegration = true;
            settings = {
              theme = "iTerm2 Default";
              command = lib.getExe pkgs.tmuxbash;
              window-decoration = false;
              gtk-single-instance = true;
              font-feature = [
                "-calt"
                "-liga"
                "-dlig"
              ];
            };
          };

        };

        services = {
          cbatticon.enable = true;
          blueman-applet.enable = true;

          syncthing.tray = {
            enable = true;
            #extraOptions = ["--wait"];
          };

          pasystray = {
            enable = true;
            extraOptions = [
              "--key-grabbing"
              "--notify=all"
            ];
          };

          gpg-agent = {
            enable = true;
            enableSshSupport = true;
            pinentry.package = pkgs.pinentry-gtk2;
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
            Requires = [ "graphical-session-pre.target" ];
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

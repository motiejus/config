{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.profiles.desktop;
  inherit (config.mj) username;
  inherit (lib)
    types
    mkOption
    ;

  brightness = pkgs.writeShellApplication {
    name = "brightness";
    text = builtins.readFile ./brightness;
  };
in
{
  options.mj.profiles.desktop = with types; {
    enableUserServices = mkOption {
      type = bool;
      default = false;
    };
  };

  imports = [
    ../basedesktop
    ../terminal
  ];

  config = {
    # https://github.com/NixOS/nixpkgs/issues/536370
    nixpkgs.config.permittedInsecurePackages = [ "pnpm-10.29.2" ];

    boot = {
      kernelModules = [ "kvm-intel" ];
    };

    hardware = {
      bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
    };

    programs = {
      firefox = {
        enable = true;
        package = pkgs.firefox-bin;
        languagePacks = [
          "en-US"
          "lt"
        ];
      };

      wireshark = {
        enable = true;
        package = pkgs.wireshark;
      };
    };

    mj.services.printing.enable = true;

    mj.base.users.user.extraGroups = [
      "networkmanager"
      "wireshark"
    ];

    services = lib.mkIf cfg.enableUserServices {
      blueman.enable = true;
      udev.packages = [ pkgs.yubikey-personalization ];
      gnome.gnome-keyring.enable = true;
      openssh.settings.X11Forwarding = true;

      pulseaudio = {
        enable = true;
        package = pkgs.pulseaudioFull;
      };

      logind.settings.Login = {
        HandlePowerKey = "suspend";
        HandlePowerKeyLongPress = "poweroff";
        HandleLidSwitchExternalPower = "ignore";
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

    fonts.packages = with pkgs; [
      xkcd-font
    ];

    environment.systemPackages = with pkgs; [
      # packages defined here
      nicer
      brightness

      android-tools
      f3 # flight-flash-fraud
      gdb
      ntp
      sox
      mpv
      imv # image viewer
      gimp
      qemu
      xclip
      pdftk
      scrot
      dillo
      typst
      sioyek
      cowsay
      xboard
      (kazam.override {
        python3Packages = pkgs.python311Packages;
      }) # alternative to gtk-recordMyDesktop
      x11vnc
      tinycc
      cheese
      arandr
      evince
      ioping
      motion
      gthumb
      csvkit
      calibre
      gparted
      scribus
      gnumake
      libwebp
      librsvg
      picocom
      libheif
      mplayer
      tcpflow
      fairymax
      ddrescue
      gcompris
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
      get_iplayer
      #ventoy-full
      pavucontrol
      photocollage
      libqalculate # qalc
      qalculate-qt # qalculate
      google-chrome
      wirelesstools
      squashfsTools
      aspellDicts.en
      aspellDicts.lt
      libreoffice-qt
      graphicsmagick
      signal-desktop # https://github.com/NixOS/nixpkgs/issues/536370
      gnome-calendar
      element-desktop
      netsurf-browser
      man-pages-posix
      gnome-calculator
      kdePackages.okular
      nvtopPackages.amd
      nvtopPackages.intel
      hunspellDicts.en_US
      samsung-unified-linux-driver

      xdotool
      xev
      xeyes
      lndir
      xinit

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
            settings = {
              window-decoration = false;
              gtk-single-instance = true;
            };
          };

          chromium = lib.mkIf pkgs.stdenv.isLinux {
            enable = true;
            extensions = [
              { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; } # ublock origin
              { id = "mdjildafknihdffpkfmmpnpoiajfjnjd"; } # consent-o-matic
            ];
          };

          firefox = {
            enable = true;
            package = pkgs.firefox-bin;
            configPath = ".mozilla/firefox";
            policies.DisableAppUpdate = true;
            profiles = {
              xdefault = {
                isDefault = true;
                settings = {
                  "app.update.auto" = false;
                  "browser.uidensity" = 1;
                  "browser.aboutConfig.showWarning" = false;
                  "browser.contentblocking.category" = "strict";
                  "browser.urlbar.showSearchSuggestionsFirst" = false;
                  "layout.css.prefers-color-scheme.content-override" = 0;
                  "signon.management.page.breach-alerts.enabled" = false;
                  "signon.rememberSignons" = false;

                  # go/
                  "browser.fixup.domainwhitelist.go" = true;
                };
                extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
                  bitwarden
                  ublock-origin
                  consent-o-matic
                  multi-account-containers
                ];
              };
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
            enable = lib.mkDefault true;
            xautolock.enable = false;
            lockCmd = ''${pkgs.bash}/bin/bash -c "${pkgs.coreutils}/bin/sleep 0.2; ${pkgs.xset}/bin/xset dpms force off; /run/wrappers/bin/slock"'';
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
            package = pkgs.kdePackages.breeze-gtk;
            name = "Breeze";
          };
          cursorTheme = {
            package = pkgs.kdePackages.breeze-icons;
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
          gtk4.theme = null;
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

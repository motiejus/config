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
in
{
  imports = [ ../dev ];
  config = {
    boot = {
      loader.systemd-boot.enable = true;
      initrd.systemd.enable = true;
      supportedFilesystems = [
        "exfat"
        "ntfs"
        "xfs"
      ];
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
      fwupd.enable = true;
      blueman.enable = true;
      udev.packages = [ pkgs.yubikey-personalization ];
      acpid.enable = true;
      pcscd.enable = true;
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

      tlp = {
        enable = true;
        settings = {
          START_CHARGE_THRESH_BAT0 = lib.mkDefault 80;
          STOP_CHARGE_THRESH_BAT0 = lib.mkDefault 87;
        };
      };

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

    virtualisation.docker.enable = true;

    environment.systemPackages =
      with pkgs;
      [
        # packages defined here
        nicer
        tmuxbash
        brightness

        f3 # flight-flash-fraud
        iw
        rr
        gdb
        ntp
        i7z
        vlc
        sox
        mpv
        imv # image viewer
        acpi
        gimp
        josm
        gdal
        qemu
        zlib
        ninja
        xclip
        pdftk
        putty
        scrot
        tracy
        mb2md # mailbox2maildir
        cmake
        (kazam.override {
          python3Packages = pkgs.python311Packages;
        }) # alternative to gtk-recordMyDesktop
        x11vnc
        yt-dlp
        skopeo
        ffmpeg
        tinycc
        scrcpy
        cheese
        arandr
        pandoc
        evince
        motion
        gthumb
        calibre
        gparted
        scribus
        gnumake
        libwebp
        librsvg
        neomutt
        picocom
        inferno
        libheif
        mplayer
        tcpflow
        cppcheck
        wasmtime
        undocker
        nautilus
        smplayer
        inkscape
        chromium
        hunspell
        tigervnc
        bsdgames
        xss-lock
        valgrind
        musl.dev
        audacity
        graphviz
        powertop
        librecad
        qgis-ltr # qgis gets recompiled, qgis-ltr is cached by hydra
        tesseract
        trayscale
        espeak-ng
        man-pages
        rox-filer
        distrobox
        miniupnpc
        v4l-utils
        #nerdfonts
        postgresql
        winetricks
        diffoscope
        alsa-utils
        gcc_latest
        shellcheck
        borgbackup
        efibootmgr
        virtualenv
        imagemagick
        #ventoy-full
        ghostscript
        libva-utils # intel video tests
        pavucontrol
        photocollage
        libqalculate # qalc
        qalculate-qt # qalculate
        google-chrome
        wirelesstools
        poppler_utils
        rkdeveloptool
        squashfsTools
        nixpkgs-review
        joplin-desktop
        aspellDicts.en
        aspellDicts.lt
        libreoffice-qt
        graphicsmagick
        magic-wormhole
        signal-desktop
        gnome-calendar
        intel-gpu-tools
        element-desktop
        netsurf-browser
        man-pages-posix
        git-filter-repo
        gnome-calculator
        libsForQt5.okular
        nvtopPackages.amd
        age-plugin-yubikey
        nvtopPackages.intel
        hunspellDicts.en_US
        wineWowPackages.full
        openorienteering-mapper
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

        (texlive.combine {
          inherit (texlive)
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
      ]
      ++ (with llvmPackages_19; [
        clang
        lld.dev
        llvm.dev
        clang-tools
        libllvm.dev
        libclang.dev
        llvm-manpages
        clang-manpages
        compiler-rt.dev
      ]);

    # https://discourse.nixos.org/t/nixos-rebuild-switch-upgrade-networkmanager-wait-online-service-failure/30746
    systemd.services.NetworkManager-wait-online.enable = false;

    home-manager.users.${username} =
      { pkgs, config, ... }:
      {
        imports = [ ./plasma.nix ];
        xdg.configFile = {
          "awesome/rc.lua".source = ./rc.lua;
          "gdb/gdbinit".text = ''
            set style address foreground yellow
            set style function foreground cyan
            set style string foreground magenta
          '';
        };

        programs = {
          msmtp.enable = true;
          mbsync.enable = true;
          neomutt.enable = true;
          notmuch.enable = true;
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

          tmux.extraConfig =
            let
              cmd = "${pkgs.extract_url}/bin/extract_url";
              cfg = pkgs.writeText "urlviewrc" "COMMAND systemd-run --user --collect xdg-open %s";
            in
            ''
              bind-key u capture-pane -J \; \
                save-buffer /tmp/tmux-buffer \; \
                delete-buffer \; \
                split-window -l 10 "${cmd} -c ${cfg} /tmp/tmux-buffer"
            '';
        };

        accounts.email = {
          maildirBasePath = "Maildir";

          accounts.mj = {
            primary = true;
            userName = "motiejus@jakstys.lt";
            address = "motiejus@jakstys.lt";
            realName = "Motiejus Jakštys";
            passwordCommand = "cat /home/${username}/.mail-appcode";
            imap.host = "imap.gmail.com";
            smtp.host = "smtp.gmail.com";

            mbsync = {
              enable = true;
              create = "maildir";
              patterns = [
                "*"
                "![Gmail]/All Mail"
              ];
            };

            msmtp = {
              enable = true;
            };

            notmuch = {
              enable = true;
              neomutt.enable = true;
            };

            neomutt = {
              enable = true;
              extraConfig = ''
                set index_format="%4C %Z %{%F %H:%M} %-15.15L (%?l?%4l&%4c?) %s"

                set mailcap_path = ${pkgs.writeText "mailcaprc" ''
                  text/html; ${pkgs.elinks}/bin/elinks -dump ; copiousoutput;
                  application/*; ${pkgs.xdg-utils}/bin/xdg-open %s &> /dev/null &;
                  image/*; ${pkgs.xdg-utils}/bin/xdg-open %s &> /dev/null &;
                ''}
                auto_view text/html
                unset record
                set send_charset="utf-8"

                macro attach 'V' "<pipe-entry>iconv -c --to-code=UTF8 > ~/.cache/mutt/mail.html<enter><shell-escape>firefox ~/.cache/mutt/mail.html<enter>"
                macro index,pager \cb "<pipe-message> env BROWSER=firefox urlscan<Enter>" "call urlscan to extract URLs out of a message"
                macro attach,compose \cb "<pipe-entry> env BROWSER=firefox urlscan<Enter>" "call urlscan to extract URLs out of a message"

                set sort_browser=date
                set sort=reverse-threads
                set sort_aux=last-date-received

                bind pager g top
                bind pager G bottom
                bind attach,index g first-entry
                bind attach,index G last-entry
                bind attach,index,pager \CD half-down
                bind attach,index,pager \CU half-up
                bind attach,index,pager \Ce next-line
                bind attach,index,pager \Cy previous-line
                bind index,pager B sidebar-toggle-visible
                bind index,pager R group-reply

                set sidebar_visible = yes
                set sidebar_width = 15
                bind index,pager \Cp sidebar-prev
                bind index,pager \Cn sidebar-next
                bind index,pager \Co sidebar-open
                bind index,pager B sidebar-toggle-visible
                set sidebar_short_path = yes
                set sidebar_delim_chars = '/'
                set sidebar_format = '%B%* %?N?%N?'
                set mail_check_stats
                set postponed="+[Gmail]/Drafts"
                mailboxes =btrfs
                mailboxes =Debian
                mailboxes =alerts
                mailboxes ="[Gmail]/Drafts"
                mailboxes ="[Gmail]/Starred"
                mailboxes ="[Gmail]/Sent Mail"

                source ${./notmuch-colors.muttrc}
              '';
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

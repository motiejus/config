{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj;
in
{
  imports = [
    ./boot
    ./fileSystems
    ./snapshot
    ./sshd
    ./unitstatus
    ./users
    ./zfs
    ./zfsborg
  ];

  options.mj = with lib.types; {
    stateVersion = lib.mkOption {
      type = str;
      example = "22.11";
      description = "The NixOS state version to use for this system";
    };

    timeZone = lib.mkOption {
      type = str;
      example = "Europe/Vilnius";
      description = "Time zone for this system";
    };

    username = lib.mkOption { type = str; };

    skipPerf = lib.mkOption {
      type = bool;
      default = false;
    };
  };

  config = {
    boot = {
      # https://github.com/NixOS/nixpkgs/issues/83694#issuecomment-605657381
      kernel.sysctl = {
        "kernel.sysrq" = "438";
        "kernel.perf_event_paranoid" = "-1";
        "kernel.kptr_restrict" = "0";
      };

      kernelPackages = lib.mkDefault pkgs.linuxPackages;

      supportedFilesystems = [ "btrfs" ];
    };

    nixpkgs.config.allowUnfree = true;

    hardware.enableRedistributableFirmware = true;

    time.timeZone = cfg.timeZone;

    mj.services.friendlyport.ports = [
      {
        subnets = [ myData.subnets.tailscale.cidr ];
        tcp = [ config.services.iperf3.port ];
        udp = [ config.services.iperf3.port ];
      }
    ];

    i18n = {
      defaultLocale = "en_US.UTF-8";
      supportedLocales = [ "all" ];
    };

    nix = {
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
      };
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ cfg.username ];
      };
    };

    system.stateVersion = cfg.stateVersion;

    security = {
      sudo = {
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };
    };

    environment = {
      systemPackages =
        with pkgs;
        lib.mkMerge [
          [
            bc
            jc # parse different formats and command outputs to json
            jq # parse, format and query json documents
            yq
            pv # pipe viewer for progressbars in pipes
            bat # "bat - cat with wings", cat|less with language highlight
            duf # nice disk usage output
            git
            lz4
            fio
            htop
            file # file duh
            host # look up host info
            tree # tree duh
            lsof # lsof yay
            rage # encrypt-decrypt
            ncdu # disk usage navigator
            btdu
            lshw
            entr
            cloc
            poop # hopefully poof some day
            flex
            bison
            s-tui # stress and monitor cpu
            iotop
            wdiff
            tokei
            sshfs
            pwgen
            below # tracking cgroups
            mdadm
            parted
            bloaty
            dhcpcd
            hdparm
            sdparm
            procps
            unison
            vmtouch
            vimv-rs
            sysstat
            ripgrep
            ethtool
            gettext
            bpftrace
            keyutils
            libkcapi
            usbutils
            pciutils
            bsdgames
            parallel
            yamllint
            binutils
            patchelf
            compsize # compression ratio on btrfs
            hyperfine
            stress-ng
            dmidecode
            moreutils
            cryptsetup
            lm_sensors
            inotify-info
            inotify-tools
            smartmontools
            unixtools.xxd
            bcachefs-tools
            sqlite-interactive

            # networking
            wol
            dig
            nmap
            # broken on aarch64-linux
            #wrk2
            wget
            curl
            btop
            ngrep
            iftop
            whois
            ipset
            shfmt
            iperf3
            jnettop
            openssl
            tcpdump
            testssl
            dnsutils
            bandwhich
            bridge-utils
            speedtest-cli
            nix-output-monitor

            # compression/decompression
            xz
            pigz
            zstd
            p7zip
            zopfli
            brotli

            config.boot.kernelPackages.cpupower
            config.boot.kernelPackages.vm-tools
          ]
          (lib.mkIf (!cfg.skipPerf) [ config.boot.kernelPackages.perf ])
        ];
    };

    programs = {
      nano.enable = false;
      mtr.enable = true;
      bcc.enable = true;

      tmux = {
        enable = true;
        keyMode = "vi";
        historyLimit = 1000000;
      };

      neovim = {
        enable = true;
        vimAlias = true;
        defaultEditor = true;
      };
    };

    networking.firewall.logRefusedConnections = false;

    services = {
      iperf3.enable = true;

      chrony = {
        enable = true;
        servers = [ "time.cloudflare.com" ];
      };

      locate = {
        enable = true;
        package = pkgs.plocate;
        localuser = null;
      };
    };
  };
}

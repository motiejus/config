{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
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
  };

  config = {
    nixpkgs.config.allowUnfree = true;
    hardware.enableRedistributableFirmware = true;

    time.timeZone = config.mj.timeZone;

    mj.services.friendlyport.ports = [
      {
        subnets = [myData.subnets.tailscale.cidr];
        tcp = [config.services.iperf3.port];
        udp = [config.services.iperf3.port];
      }
    ];

    i18n = {
      defaultLocale = "en_US.UTF-8";
      supportedLocales = [
        "en_US.UTF-8/UTF-8"
        "lt_LT.UTF-8/UTF-8"
      ];
    };

    nix = {
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 14d";
      };
      settings = {
        experimental-features = ["nix-command" "flakes"];
        trusted-users = ["motiejus"];
      };
    };

    system.stateVersion = config.mj.stateVersion;

    security = {
      sudo = {
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };
    };

    environment = {
      systemPackages = with pkgs; [
        jc # parse different formats and command outputs to json
        jq # parse, format and query json documents
        pv # pipe viewer for progressbars in pipes
        bat # "bat - cat with wings", cat|less with language highlight
        duf # nice disk usage output
        git
        htop
        file # file duh
        host # look up host info
        tree # tree duh
        lsof # lsof yay
        rage # encrypt-decrypt
        ncdu # disk usage navigator
        lshw
        entr
        cloc
        tokei
        pwgen
        parted
        sqlite
        bonnie # disk benchmarking
        dhcpcd
        hdparm
        sdparm
        procps
        ripgrep
        vimv-rs
        sysstat
        usbutils
        pciutils
        bsdgames
        parallel
        binutils
        hyperfine
        sloccount
        dmidecode
        moreutils
        perf-tools
        smartmontools
        unixtools.xxd

        # networking
        dig
        nmap
        ngrep
        wget
        curl
        btop
        iftop
        whois
        ipset
        iperf3
        jnettop
        openssl
        tcpdump
        testssl
        dnsutils
        speedtest-cli
        prettyping
        (runCommand "prettyping-pp" {} ''
          mkdir -p $out/bin
          ln -s ${prettyping}/bin/prettyping $out/bin/pp
        '')

        # compression/decompression
        xz
        pigz
        zstd
        p7zip
        brotli
        zopfli
      ];
    };

    programs = {
      mtr.enable = true;

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

      sysdig.enable = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
    };

    networking.firewall.logRefusedConnections = false;

    services = {
      iperf3.enable = true;

      chrony = {
        enable = true;
        servers = ["time.cloudflare.com"];
      };

      locate = {
        enable = true;
        locate = pkgs.plocate;
        localuser = null;
      };
    };
  };
}

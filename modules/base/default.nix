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
        "C.UTF-8/UTF-8"
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
        poop # hopefully poof some day
        tokei
        pwgen
        parted
        sqlite
        dhcpcd
        hdparm
        sdparm
        procps
        vimv-rs
        sysstat
        ripgrep
        ethtool
        usbutils
        pciutils
        bsdgames
        parallel
        binutils
        hyperfine
        stress-ng
        dmidecode
        moreutils
        lm_sensors
        perf-tools
        smartmontools
        unixtools.xxd

        # networking
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
        iperf3
        jnettop
        openssl
        tcpdump
        testssl
        dnsutils
        bandwhich
        speedtest-cli
        config.boot.kernelPackages.perf

        # compression/decompression
        xz
        pigz
        zstd
        p7zip
        zopfli
        brotli
      ];
    };

    programs = {
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

      # TODO
      # error: builder for '/nix/store/3d6dl3p6vh6q167f476g0jd5k9lf40vx-sysdig-0.33.1.drv' failed with exit code 2;
      #        last 10 log lines:
      #        > make[4]: *** [/nix/store/dx2530rhfk0wpwwvqjxb5bsxjqwrlmv2-linux-6.6.2-dev/lib/modules/6.6.2/source/Makefile:234: __sub-make] Error 2
      #        > make[3]: *** [Makefile:16: all] Error 2
      #        > make[2]: *** [driver/CMakeFiles/driver.dir/build.make:70: driver/CMakeFiles/driver] Error 2
      #        > make[1]: *** [CMakeFiles/Makefile2:602: driver/CMakeFiles/driver.dir/all] Error 2
      #        > make[1]: *** Waiting for unfinished jobs....
      #        > [ 32%] Linking CXX static library libcri_v1alpha2.a
      #        > [ 32%] Built target cri_v1alpha2
      #        > [ 33%] Linking CXX static library libcri_v1.a
      #        > [ 33%] Built target cri_v1
      #        > make: *** [Makefile:156: all] Error 2
      #        For full logs, run 'nix log /nix/store/3d6dl3p6vh6q167f476g0jd5k9lf40vx-sysdig-0.33.1.drv'.
      # error: 1 dependencies of derivation '/nix/store/lya9lrjxyfx1pql568d88x3j9kqsndar-kernel-modules.drv' failed to build
      # error: 1 dependencies of derivation '/nix/store/08xhqi0rmd4i9i7qm4r559mqmv1k4iff-linux-6.6.2-modules.drv' failed to build
      # error: 1 dependencies of derivation '/nix/store/hy9c4szjba6mxn9bwa4yxjiv9vbnp657-nixos-system-vno1-oh2-23.11.20231128.7c4c205.drv' failed to build
      # error: 1 dependencies of derivation '/nix/store/p7rx1li894pfyc6s6nz5f6jdcdjvl3xi-activatable-nixos-system-vno1-oh2-23.11.20231128.7c4c205.drv' failed to build
      # error: 1 dependencies of derivation '/nix/store/r0szq7sqarjk5mrhhb3w8vn9li8c43lz-deploy-rs-check-activate.drv' failed to build
      # error: build of '/nix/store/gwc35cfp7ndxyz4vs7i9r123hmbr90r3-jsonschema-deploy-system.drv', '/nix/store/r0szq7sqarjk5mrhhb3w8vn9li8c43lz-deploy-rs-check-activate.drv' failed
      # 🚀 ❌ [deploy] [ERROR] Failed to check deployment: Nix checking command resulted in a bad exit code: Some(1)

      #sysdig.enable = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
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
        package = pkgs.plocate;
        localuser = null;
      };
    };
  };
}

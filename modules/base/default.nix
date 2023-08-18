{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./boot
    ./initrd
    ./fileSystems
    ./snapshot
    ./sshd
    ./sshguard
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
    time.timeZone = config.mj.timeZone;

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
        dates = "daily";
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
        tmux
        htop
        file # file duh
        host # look up host info
        tree # tree duh
        lsof # lsof yay
        rage # encrypt-decrypt
        ncdu # disk usage navigator
        pwgen
        parted
        sqlite
        procps
        ripgrep
        vimv-rs
        sysstat
        nix-top # nix-top is a top for what nix is doing
        bsdgames
        binutils
        moreutils
        perf-tools
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

      sysdig.enable = pkgs.stdenv.hostPlatform.system == "x86_64-linux";

      vim.defaultEditor = true;
    };

    services = {
      locate = {
        enable = true;
        locate = pkgs.plocate;
        localuser = null;
      };
    };
  };
}

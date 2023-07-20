{
  config,
  myData,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./initrd
    ./snapshot
    ./sshd
    ./unitstatus
    ./zfsborg
  ];

  options.mj = {
    stateVersion = lib.mkOption {
      type = lib.types.str;
      example = "22.11";
      description = "The NixOS state version to use for this system";
    };
    timeZone = lib.mkOption {
      type = lib.types.str;
      example = "Europe/Vilnius";
      description = "Time zone for this system";
    };

    stubPasswords = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = {
    time.timeZone = config.mj.timeZone;

    # Select internationalisation properties.
    i18n = {
      defaultLocale = "en_US.UTF-8";
      supportedLocales = [
        "lt_LT.UTF-8/UTF-8"
      ];
    };

    nix.settings.experimental-features = ["nix-command" "flakes"];

    system.stateVersion = config.mj.stateVersion;

    security = {
      sudo = {
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };
    };

    users = let
      withPasswordFile = file: attrs:
        (
          if config.mj.stubPasswords
          then {
            initialPassword = "live";
          }
          else {
            passwordFile = file;
          }
        )
        // attrs;
    in {
      mutableUsers = false;

      users = {
        motiejus = withPasswordFile config.age.secrets.motiejus-passwd-hash.path {
          isNormalUser = true;
          extraGroups = ["wheel"];
          uid = 1000;
          openssh.authorizedKeys.keys = [myData.ssh_pubkeys.motiejus];
        };

        root = withPasswordFile config.age.secrets.root-passwd-hash.path {};
      };
    };

    environment = {
      systemPackages = with pkgs; [
        jc # parse different formats and command outputs to json
        jq # parse, format and query json documents
        pv # pipe viewer for progressbars in pipes
        bat # "bat - cat with wings", cat|less with language highlight
        duf # nice disk usage output
        file # file duh
        host # look up host info
        tree # tree duh
        lsof # lsof yay
        rage # encrypt-decrypt
        #ncdu # disk usage navigator
        pwgen
        sqlite
        direnv
        ripgrep
        vimv-rs
        nix-top # nix-top is a top for what nix is doing
        binutils
        moreutils
        unixtools.xxd

        # networking
        dig
        nmap
        wget
        curl
        whois
        ipset
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

      variables = {
        EDITOR = "nvim";
      };
    };

    programs = {
      mtr.enable = true;
      neovim = {
        enable = true;
        defaultEditor = true;
      };
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj;
in
{
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

  };

  config = {
    nixpkgs.config.allowUnfree = true;

    time.timeZone = cfg.timeZone;

    nix = {
      gc = {
        automatic = true;
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

    environment = {
      systemPackages =
        with pkgs;
        lib.mkMerge [
          [
            bc
            jc # parse different formats and command outputs to json
            jq # parse, format and query json documents
            yq
            xz
            pv # pipe viewer for progressbars in pipes
            bat # "bat - cat with wings", cat|less with language highlight
            duf # nice disk usage output
            git
            lz4
            mmv
            htop
            file # file duh
            host # look up host info
            tree # tree duh
            lsof # lsof yay
            rage # encrypt-decrypt
            ncdu # disk usage navigator
            entr
            pigz
            zstd
            unrar
            wdiff
            sshfs
            pwgen
            zopfli
            brotli
            bindfs
            spiped
            unison
            vmtouch
            vimv-rs
            ripgrep
            gettext
            exiftool
            usbutils
            pciutils
            parallel
            yamllint
            dos2unix
            rtorrent
            p7zip-rar
            moreutils
            smartmontools
            unixtools.xxd
            sqlite-interactive

            # networking
            wol
            dig
            nmap
            wget
            btop
            ngrep
            iftop
            whois
            iperf3
            jnettop
            openssl
            tcpdump
            testssl
            dnsutils
            curl
            bandwhich
            speedtest-cli
            nix-output-monitor
          ]
        ];
    };

  };
}

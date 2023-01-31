# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:

let

  ssh_pubkeys = {
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
    vno1_root = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMiWb7yeSeuFCMZWarKJD6ZSxIlpEHbU++MfpOIy/2kh";
};

  mountLatest = ({mountpoint, zfs_name}:
    ''
    set -euo pipefail
    ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest || : &>/dev/null
    mkdir -p ${mountpoint}/.snapshot-latest
    ${pkgs.util-linux}/bin/mount -t zfs $(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name ${zfs_name} | sort | tail -1) ${mountpoint}/.snapshot-latest
    ''
  );

  umountLatest = ({mountpoint, ...}:
    ''set -euo pipefail
    ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest
    ''
  );

  backup_paths = {
    var_lib = {
      mountpoint = "/var/lib";
      zfs_name = "rpool/nixos/var/lib";
      paths = [
        "/var/lib/.snapshot-latest/gitea"
        "/var/lib/.snapshot-latest/headscale"
      ];
      backup_at = "*-*-* *:01:00";
    };
    var_log = {
      mountpoint = "/var/log";
      zfs_name = "rpool/nixos/var/log";
      paths = [ "/var/log/.snapshot-latest/caddy/" ];
      patterns = [
        "+ /var/log/.snapshot-latest/caddy/access-beta.jakstys.lt.log-*.zst"
        "- *"
      ];
      backup_at = "*-*-* 00:10:00";
    };
  };

in {
  imports =
    [
      /etc/nixos/hardware-configuration.nix /etc/nixos/zfs.nix
    ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      authorizedKeys = builtins.attrValues ssh_pubkeys;
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  security.sudo = {
    wheelNeedsPassword = false;
    execWheelOnly = true;
  };

  time.timeZone = "UTC";

  users = {
    mutableUsers = false;

    users = {
      git = {
        description = "Gitea Service";
        home = "/var/lib/gitea";
        useDefaultShell = true;
        group = "gitea";
        isSystemUser = true;
      };

      motiejus = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ ssh_pubkeys.motiejus ];
      };
    };
  };

  environment.systemPackages = with pkgs; [
    jq
    vim
    git
    tmux
    tree
    wget
    lsof
    file
    htop
    #ncdu
    sqlite
    ripgrep
    binutils
    pciutils
    headscale
    nixos-option
  ];

  programs.mtr.enable = true;
  programs.mosh.enable = true;
  programs.ssh.knownHosts = {
    "vno1-oh2.servers.jakst" = {
        extraHostNames = ["dl.jakstys.lt" "vno1-oh2.jakstys.lt"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINCJxdEkgQ3U0XxqDibk0g3iV+FG423Yk8hj6VAIOpT5";
    };
    "hel1-a.servers.jakst" = {
        extraHostNames = ["hel1-a.jakstys.lt" "git.jakstys.lt" "vpn.jakstys.lt"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6Wd2lKrpP2Gqul10obMo2dc1xKaaLv0I4FAnfIaFKu";
    };
    "hel1-b.servers.jakst" = {
        extraHostNames = ["hel1-b.jakstys.lt" "jakstys.lt"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINCJxdEkgQ3U0XxqDibk0g3iV+FG423Yk8hj6VAIOpT5";
    };
    "mtwork.motiejus.jakst" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOvNuABV5KXmh6rmS+R50XeJ9/V+Sgpuc1DrlYXW2bQb";
    };
    "zh2769.rsync.net" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
    };

    "github.com" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
  };

  services = {
    zfs = {
      autoScrub.enable = true;
      trim.enable = true;
      expandOnBoot = "all";
    };

    sanoid = {
      enable = true;
      templates.prod = {
        hourly = 24;
        daily = 7;
        autosnap = true;
        autoprune = true;
      };
      datasets = lib.mapAttrs' (name: value: {
          name = value.zfs_name;
          value = { use_template = ["prod"]; };
        }) backup_paths;
      extraArgs = [ "--verbose" ];
    };

    borgbackup.jobs = lib.mapAttrs' (name: value:
      let
        snapshot = { mountpoint = value.mountpoint; zfs_name = value.zfs_name; };
        rwpath = value.mountpoint + "/.snapshot-latest";
      in {
        name = name;
        value = {
          doInit = true;
          repo = "zh2769@zh2769.rsync.net:borg";
          encryption = {
            mode = "repokey-blake2";
            passCommand = "cat /var/src/secrets/borgbackup/password";
          };
          paths = value.paths;
          extraArgs = "--remote-path=borg1";
          compression = "auto,lzma";
          startAt = value.backup_at;
          readWritePaths = [ rwpath ];
          preHook = mountLatest snapshot;
          postHook = umountLatest snapshot;
          prune.keep = {
            within = "1d";
            daily = 7;
            weekly = 4;
            monthly = 3;
          };
        } // lib.optionalAttrs (value ? patterns) {
          patterns = value.patterns;
        };
      }) backup_paths;

    openssh = {
      enable = true;
      passwordAuthentication = false;
      permitRootLogin = "no";
      extraConfig = ''
        AcceptEnv GIT_PROTOCOL
      '';
    };

    locate = {
      enable = true;
      locate = pkgs.plocate;
      localuser = null;
    };

    headscale = {
      enable = true;
      serverUrl = "https://vpn.jakstys.lt";
      openIdConnect = {
        issuer = "https://git.jakstys.lt/";
        clientId = "1c5fe796-452c-458d-b295-71a9967642fc";
        clientSecretFile = "/var/lib/headscale/oidc_client_secret"; # https://github.com/juanfont/headscale/pull/1127
      };
      settings = {
        ip_prefixes = [
          "100.89.176.0/20"
          "fd7a:115c:a1e0:59b0::/64"
        ];
        dns_config = {
          nameservers = [ "1.1.1.1" "8.8.4.4" ];
          magic_dns = true;
          base_domain = "jakst";
        };
      };
    };

    tailscale.enable = true;

    gitea = {
      enable = true;
      user = "git";
      database.user = "git";
      domain = "git.jakstys.lt";
      rootUrl = "https://git.jakstys.lt";
      httpAddress = "127.0.0.1";
      httpPort = 3000;
      settings = {
        admin.DISABLE_REGULAR_ORG_CREATION = true;
        api.ENABLE_SWAGGER = false;
        mirror.ENABLED = false;
        other.SHOW_FOOTER_VERSION = false;
        packages.ENABLED = false;
        repository.DEFAULT_REPO_UNITS = "repo.code,repo.releases";
        repository.DISABLE_MIGRATIONS = true;
        repository.DISABLE_STARS = true;
        repository.ENABLE_PUSH_CREATE_USER = true;
        security.LOGIN_REMEMBER_DAYS = 30;
        server.ENABLE_GZIP = true;
        server.LANDING_PAGE = "/motiejus";
        service.DISABLE_REGISTRATION = true;
        service.ENABLE_TIMETRACKING = false;
        service.ENABLE_USER_HEATMAP = false;
        service.SHOW_MILESTONES_DASHBOARD_PAGE = false;
        session.COOKIE_SECURE = true;
        "service.explore".DISABLE_USERS_PAGE = true;
      };
    };

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      virtualHosts."vpn.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:8080
      '';
      virtualHosts."git.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
      virtualHosts."beta.jakstys.lt" = {
        logFormat = ''
            output file ${config.services.caddy.logDir}/access-beta.jakstys.lt.log {
              roll_disabled
            }
        '';
        extraConfig = ''
          header /_/* Cache-Control "public, max-age=31536000, immutable"
          root * /var/www/jakstys.lt
          file_server {
            precompressed br gzip
          }

          @matrixMatch {
            path /.well-known/matrix/client
            path /.well-known/matrix/server
          }
          header @matrixMatch Content-Type application/json
          header @matrixMatch Access-Control-Allow-Origin *
          header @matrixMatch Cache-Control "public, max-age=3600, immutable"

          handle /.well-known/matrix/client {
            respond "{\"m.homeserver\": {\"base_url\": \"https://jakstys.lt\"}}" 200
          }
          handle /.well-known/matrix/server {
            respond "{\"m.server\": \"jakstys.lt:443\"}" 200
          }

          handle /_matrix/* {
            reverse_proxy http://hel1-b.servers.jakst:8088
          }
        '';
      };
    };

    logrotate = {
      settings = {
        "/var/log/caddy/access-beta.jakstys.lt.log" = {
          rotate = 60;
          frequency = "daily";
          dateext = true;
          dateyesterday = true;
          compress = true;
          compresscmd = "${pkgs.zstd}/bin/zstd";
          compressext = ".zst";
          compressoptions = "--long -19";
          uncompresscmd = "${pkgs.zstd}/bin/unzstd";
          postrotate = "${pkgs.systemd}/bin/systemctl restart caddy";
        };
      };
    };
  };

  # TODO: compress static stuff
  #${pkgs.findutils}/bin/find ${pkgs.gitea.data} -name '*.css' -exec ${pkgs.brotli}/bin/brotli {} \+

  networking = {
    hostName = "hel1-a";
    firewall = {
      allowedTCPPorts = [ 80 443 ];
      allowedUDPPorts = [ 443 ];
      checkReversePath = "loose"; # tailscale insists on this
    };
  };

  system = {
    copySystemConfiguration = true;
    autoUpgrade.enable = true;
    autoUpgrade = {
      allowReboot = true;
      rebootWindow = {
        lower = "01:00";
        upper = "01:30";
      };
    };
  };

  # TODO static snapshots
  systemd.services."make-snapshot-dirs" = let
    vals = builtins.attrValues backup_paths;
    mountpoints = builtins.catAttrs "mountpoint" vals;
    unique_mountpoints = lib.unique mountpoints;
  in {
    description = "prepare snapshot directories for backups";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = builtins.map (d: "${pkgs.coreutils}/bin/mkdir -p ${d}/.snapshot-latest") unique_mountpoints;
      RemainAfterExit = true;
    };
  };

  # Do not change
  system.stateVersion = "22.11";
}


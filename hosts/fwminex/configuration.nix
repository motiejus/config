{
  lib,
  pkgs,
  config,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A_1";
in
{
  imports = [
    ../../modules
    ../../modules/profiles/physical
    ../../modules/profiles/devtools
    ../../modules/profiles/btrfs
    ./caddy.nix
  ];

  age.secrets = {
    motiejus-server-passwd-hash.file = ../../secrets/motiejus_server_passwd_hash.age;
    root-server-passwd-hash.file = ../../secrets/root_server_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    borgbackup-password-2.file = ../../secrets/${config.networking.hostName}/borgbackup-password-2.age;
    letsencrypt-account-key.file = ../../secrets/letsencrypt/account.key.age;
    vaultwarden-secrets-env.file = ../../secrets/vaultwarden/secrets.env.age;
    synapse-jakstys-signing-key.file = ../../secrets/synapse/jakstys_lt_signing_key.age;
    synapse-registration-shared-secret.file = ../../secrets/synapse/registration_shared_secret.age;
    synapse-macaroon-secret-key.file = ../../secrets/synapse/macaroon_secret_key.age;
    syncthing-key.file = ../../secrets/fwminex/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/fwminex/syncthing/cert.pem.age;
    frigate.file = ../../secrets/frigate.age;
    timelapse.file = ../../secrets/timelapse.age;
    # owned by the capture user, so timelapse-merger runs as the user that owns
    # the photos and nothing in the tree ends up owned by root
    timelapse-merger-key = {
      file = ../../secrets/fwminex/timelapse-merger-key.age;
      owner = "timelapse-r11";
    };
    plik.file = ../../secrets/fwminex/up.jakstys.lt.env.age;
    r1-htpasswd = {
      file = ../../secrets/r1-htpasswd.age;
      owner = "caddy";
    };
    grafana-secret-key = {
      file = ../../secrets/fwminex/grafana-secret-key.age;
      owner = "grafana";
    };

    ssh8022-client = {
      file = ../../secrets/ssh8022.age;
      mode = "444";
    };

    ssh8022-server = {
      file = ../../secrets/ssh8022.age;
      owner = "spiped";
      path = "/var/lib/spiped/ssh8022.key";
    };
  };

  boot = {
    loader.systemd-boot.enable = true;
    kernelPackages = lib.mkForce pkgs.linuxPackages_latest;
    initrd = {
      systemd.enable = true;
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_crb"
      ];
    };
  };

  mj.profiles.btrfs = {
    disk = nvme;
    luksExtraConfig = {
      keyFileOffset = 9728;
      keyFileSize = 512;
      keyFile = "/dev/sda";
    };
  };

  hardware = {
    cpu.intel.updateMicrocode = true;
    coral.usb.enable = true;
    graphics = {
      enable = true;
      # AMD GPU VAAPI support
      extraPackages = with pkgs; [
        mesa # AMD GPU drivers (includes RADV)
        libva-vdpau-driver # VAAPI for AMD (formerly vaapiVdpau)
        libvdpau-va-gl # VDPAU to VA-GL bridge
      ];
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  systemd = {
    tmpfiles.rules = [ "d /var/www 0755 root root -" ];

    services = {
      weather-exporter = {
        description = "Weather exporter for Vilnius";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target.target" ];
        path = with pkgs; [
          coreutils
          jq
          curl
          bash
        ];
        serviceConfig = {
          type = "simple";
          ExecStart = "${pkgs.weather}/bin/weather -l 127.0.0.1:${toString myData.ports.exporters.weather}";
          DynamicUser = true;
        };
      };

      caddy =
        let
          wc = config.mj.services.nsd-acme.zones."jakstys.lt";
        in
        {
          preStart = ''
            for f in $CREDENTIALS_DIRECTORY/*; do
              ln -sf "$f" /run/caddy/
            done
          '';
          serviceConfig = {
            LoadCredential = [
              "jakstys.lt-cert.pem:${wc.certFile}"
              "jakstys.lt-key.pem:${wc.keyFile}"
              "up.jakstys.lt.env:${config.age.secrets.plik.path}"
            ];
            RuntimeDirectory = "caddy";
            EnvironmentFile = [ "-/run/caddy/up.jakstys.lt.env" ];
          };
          # During the first switch nginx still owns :8443. Restart ordering
          # makes it release that socket before Caddy binds both public ports.
          after = [
            "nginx.service"
            "nsd-acme-jakstys.lt.service"
          ];
          restartTriggers = [ config.age.secrets.r1-htpasswd.file ];
          requires = [ "nsd-acme-jakstys.lt.service" ];
        };

      soju =
        let
          wc = config.mj.services.nsd-acme.zones."jakstys.lt";
        in
        {
          serviceConfig = {
            RuntimeDirectory = "soju";
            LoadCredential = [
              "jakstys.lt-cert.pem:${wc.certFile}"
              "jakstys.lt-key.pem:${wc.keyFile}"
            ];
          };
          preStart = ''
            ln -sf $CREDENTIALS_DIRECTORY/jakstys.lt-cert.pem /run/soju/cert.pem
            ln -sf $CREDENTIALS_DIRECTORY/jakstys.lt-key.pem /run/soju/key.pem
          '';
          after = [ "nsd-acme-jakstys.lt.service" ];
          requires = [ "nsd-acme-jakstys.lt.service" ];
        };

      cert-watcher = {
        description = "Restart caddy+soju when tls keys/certs change";
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          StartLimitIntervalSec = 10;
          StartLimitBurst = 5;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart --no-block caddy.service soju.service";
        };
      };

    };

    paths = {
      cert-watcher = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = [
            config.mj.services.nsd-acme.zones."jakstys.lt".certFile
          ];
          Unit = "cert-watcher.service";
        };
      };
    };
  };

  services = {
    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandlePowerKey = "suspend";
      HandlePowerKeyLongPress = "poweroff";
    };

    plikd = {
      enable = true;
      settings.ListenPort = myData.ports.plik;
    };

    soju = {
      enable = true;
      listen = [
        ":${toString myData.ports.soju}"
        "wss://:${toString myData.ports.soju-ws}"
      ];
      tlsCertificate = "/run/soju/cert.pem";
      tlsCertificateKey = "/run/soju/key.pem";
      hostName = "irc.jakstys.lt";
      httpOrigins = [ "*" ];
    };

    nginx = {
      # The NixOS Frigate module's auth, websocket and VOD routes rely on
      # nginx-specific modules. Keep that application frontend private and let
      # Caddy terminate the public r1.jakstys.lt connection.
      defaultListenAddresses = [
        "127.0.0.1"
        "[::1]"
      ];
      defaultHTTPListenPort = 8081;
    };

    nsd = {
      enable = true;
      interfaces = [
        "0.0.0.0"
        "::"
      ];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
    };

    prometheus = {
      enable = true;
      port = myData.ports.prometheus;
      retentionTime = "2y";

      globalConfig = {
        # 15s would be preferable, but grafana does not allow
        # setting a refresh_interval of 15s.
        scrape_interval = "10s";
        evaluation_interval = "1m";
      };

      scrapeConfigs = [
        (
          let
            port = toString config.services.prometheus.exporters.ping.port;
            hosts = [
              "fwminex.jakst.vpn"
              "vno3-nk.jakst.vpn"
              "fra1-c.jakst.vpn"
              "vno1-gdrx.jakst.vpn"
              "vno2-desk2.jakst.vpn"
            ];
          in

          {
            job_name = "ping";
            static_configs = [ { targets = map (host: "${host}:${port}") hosts; } ];
          }
        )
        {
          job_name = "prometheus";
          static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.prometheus}" ]; } ];
        }
        {
          job_name = "caddy";
          static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.exporters.caddy}" ]; } ];
        }
        {
          job_name = "hass_p7_50";
          scrape_interval = "1m";
          metrics_path = "/api/prometheus";
          static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.hass}" ]; } ];
        }
        {
          job_name = "weather";
          scrape_interval = "10m";
          static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.exporters.weather}" ]; } ];
        }
        {
          job_name = "vno1-vinc.jakst.vpn";
          static_configs = [ { targets = [ "vno1-vinc.jakst.vpn:9100" ]; } ];
        }
        {
          job_name = "windows";
          static_configs = [ { targets = [ "vno1-vj-win.jakst.vpn:9182" ]; } ];
        }
      ]
      ++
        map
          (
            let
              port = builtins.toString myData.ports.exporters.node;
            in
            host: {
              job_name = host;
              static_configs = [ { targets = [ "${host}:${port}" ]; } ];
            }
          )
          [
            "fra1-c.jakst.vpn"
            "vno3-nk.jakst.vpn"
            "fwminex.jakst.vpn"
            "vno1-gdrx.jakst.vpn"
            "vno2-desk2.jakst.vpn"
          ];
    };

  };

  users.users.nixremote = {
    isNormalUser = true;
    home = "/home/nixremote";
    openssh.authorizedKeys.keys = [
      myData.bot_pubkeys.nixbld_macworx
    ];
  };

  nix.settings.trusted-users = [ "nixremote" ];

  mj = {
    stateVersion = "24.05";
    timeZone = "UTC";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-server-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-server-passwd-hash.path;
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      git = {
        enable = true;
        repoDir = "/var/lib/git";
        sshKeys = with myData; [
          people_pubkeys.motiejus
          people_pubkeys.motiejus_work
          people_pubkeys.motiejus_macworx
          hosts."fwminex.jakst.vpn".publicKey
        ];
      };
      lt-shelters.enable = true;
      hass.enable = true;
      syncthing-relay.enable = true;

      ping_exporter.enable = true;

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      frigate = {
        enable = true;
        secretsEnv = config.age.secrets.frigate.path;
      };

      timelapse-r11 = {
        enable = true;
        web.enable = true;
        onCalendar = "*-*-* *:0/5:00";
        secretsEnv = config.age.secrets.timelapse.path;
        archiveFrom = "timelapse-r11@vno3-nk.jakst.vpn";
        readerKeys = [ myData.bot_pubkeys.timelapse_merger_vno3_nk ];
      };

      immich = {
        enable = true;
        bindPaths = {
          "M-Camera" = "/home/motiejus/annex2/M-Camera";
          "Pictures" = "/home/motiejus/annex2/Pictures";
        };
      };

      ssh8022 = {
        client = {
          enable = true;
          keyfile = config.age.secrets.ssh8022-client.path;
        };

        server = {
          enable = true;
          keyfile = config.age.secrets.ssh8022-server.path;
        };
      };

      borgstor = {
        enable = true;
        dataDir = "/var/lib/borgstor";
        sshKeys = with myData; [
          hosts."vno3-nk.jakst.vpn".publicKey
          people_pubkeys.motiejus
        ];
      };

      vaultwarden = {
        enable = true;
        port = myData.ports.vaultwarden;
        secretsEnvFile = config.age.secrets.vaultwarden-secrets-env.path;
      };

      minidlna = {
        enable = true;
        paths = [ "/home/motiejus/video" ];
      };

      grafana = {
        enable = true;
        port = myData.ports.grafana;
        secretKeyPath = config.age.secrets.grafana-secret-key.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = false;
        acceptDNS = true;
      };

      rita-jakst-publisher.enable = true;

      dl-mirror.sender = {
        enable = true;
        destination = "dl-receiver@fra1-c.jakst.vpn";
      };
      mb-type-fonts.enable = true;

      nsd-acme =
        let
          accountKey = config.age.secrets.letsencrypt-account-key.path;
        in
        {
          enable = true;
          zones = {
            "jakstys.lt" = {
              inherit accountKey;
              extraDomains = [ "*.jakstys.lt" ];
            };
          };
        };

      # BORG_PASSCOMMAND="sudo cat /run/agenix/borgbackup-password-2" borg info --remote-path=borg1 zh2769@zh2769.rsync.net:fwminex.jakst.vpn-state
      # BORG_RSH='ssh -i /etc/ssh/ssh_host_ed25519_key' BORG_PASSCOMMAND="sudo cat /run/agenix/borgbackup-password-2" borg info borgstor@vno3-nk.jakst.vpn:fwminex.jakst.vpn-state
      btrfsborg =
        let
          this = "${config.networking.hostName}.${config.networking.domain}";
          vno3-nk = "borgstor@vno3-nk.jakst.vpn";
          rsync-net = "zh2769@zh2769.rsync.net";
        in
        {
          enable = true;
          passwordPath = config.age.secrets.borgbackup-password-2.path;
          sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
          # Well clear of the 01:00-03:00 backups, which the check would other-
          # wise lock out of their own repository.
          checkAt = "Sun *-*-* 06:00:00 UTC";
          # Adding a folder here: pick the repository by HOW THE DATA CHANGES,
          # not by what it is. Each repo's chunker and retention are tuned for
          # one kind of change, and a folder in the wrong one costs disk or
          # index for as long as it lives there.
          #
          #   rewritten in place (databases, anything page-structured) -> state
          #   written once and kept (media, packfiles, uploads)        -> blobs
          #   bulky, immutable, worth only weeks (metrics, caches)     -> metrics
          #   already-compressed video                                 -> timelapse
          #   under /home/motiejus/annex2                              -> annex2
          #
          # Three questions, in order:
          #
          # 1. Which subvolume is it on? A job snapshots exactly one subvolume
          #    and names paths relative to it, so a folder outside /home and
          #    /var/lib cannot join an existing job at all -- it needs its own
          #    btrfssnapshot entry first, or the preHook finds no snapshot and
          #    the job fails nightly. /var/www is the live example: a plain
          #    directory, not a subvolume, so nothing under it is backed up.
          # 2. Is it rewritten, or only added to? This is the whole basis of the
          #    split. Rewritten files want the smallest chunks their writes are
          #    aligned to; write-once files want the largest, because there is no
          #    deduplication to lose and every chunk is an index entry forever.
          # 3. Is its history worth keeping? Nearly free for immutable data --
          #    593 archives of annex2 cost 2.8 GB between them -- and expensive
          #    for anything rewritten nightly, which is why only state carries a
          #    ladder and the rest keep everything.
          #
          # Adding a folder to an existing repo is free: borg deduplicates it
          # against what is there and uploads it once. Changing a repo's chunker
          # is not, because borg cannot re-chunk in place. A folder that fits
          # none of the rows wants its own repo rather than a compromise -- state
          # and blobs were one repo until the databases and the blobs turned out
          # to want opposite chunkers.
          dirs =
            builtins.concatMap
              (host: [

                # The files that get rewritten in place: one 6.5 GB SQLite a
                # night, plus the smaller databases. A page-aligned fixed chunker
                # stores a night of that in 0.085 GB where 64 KiB content-defined
                # chunks need 0.356 and 2 MiB need 1.378 -- a sixteenfold spread
                # on one file, measured over six real nights. The index it buys
                # that with is 1.8M chunks and 843 MB of RSS for 7.7 GB of data,
                # which is why nothing else lives here.
                {
                  subvolume = "/var/lib";
                  repo = "${host}:${this}-state";
                  paths = [
                    "hass"
                    "caddy"
                    "grafana"
                    "bitwarden_rs"
                    "matrix-synapse"
                    "private/soju"
                    "rita.jakstys.lt"
                    "postgresql"
                  ];
                  # Blobs, not pages: media_store belongs with the other blobs.
                  exclude = [ "matrix-synapse/media_store" ];
                  chunkerParams = "fixed,4096";
                  prune.keep = {
                    last = 3;
                    daily = 14;
                    weekly = 8;
                    monthly = 12;
                  };
                  backup_at = "*-*-* 01:00:01 UTC";
                }
                # Written once and never rewritten, so a night costs 0.015 GB and
                # history is nearly free. 64 KiB measured smallest at thirty
                # archives, 12.47 GB against 13.42 at 4 MiB; the initial sizes are
                # within noise of each other and were not what decided it.
                {
                  subvolume = "/var/lib";
                  repo = "${host}:${this}-blobs";
                  paths = [
                    "git"
                    "matrix-synapse/media_store"

                    # https://immich.app/docs/administration/backup-and-restore/
                    "immich/library"
                    "immich/upload"
                    "immich/profile"
                  ];
                  # A mirror of Linus' tree: 6.5 GB of the 7.0 GB under git/,
                  # and kernel.org keeps a copy.
                  exclude = [ "git/linux.git" ];
                  prune.keep = {
                    within = "10y";
                    last = 3;
                  };
                  backup_at = "*-*-* 01:10:01 UTC";
                }
                # Two years of metrics, 100 GB of the 129 GB this host stored,
                # and the only data here worth just four weeks. Its own repo so
                # that retention can say so; the module default is that policy.
                # Blocks are immutable and a compaction re-encodes rather than
                # rewrites -- the night one merged seven blocks cost 0.55-0.59 GB
                # under every chunker tried -- so nothing deduplicates and the
                # largest chunker is free: 4 MiB was smaller on every axis than
                # 64 KiB, down to 2317 unique chunks against 108785. Level 10
                # earns its CPU here, unlike anywhere else: 3.6%.
                {
                  subvolume = "/var/lib";
                  repo = "${host}:${this}-metrics";
                  paths = [ "prometheus2" ];
                  chunkerParams = "buzhash,19,23,22,4095";
                  compression = "auto,zstd,10";
                  backup_at = "*-*-* 01:20:01 UTC";
                }
                # One video a camera a month, never rebuilt once finished. The
                # frames are already compressed, so compression only burns CPU,
                # and 4 MiB chunks index it in a fortieth of the entries 64 KiB
                # would need, with no deduplication to give up. Not measured --
                # there is no copy of this data to measure against -- but it is
                # the same shape as the immutable prometheus blocks, where the
                # largest chunker won on every axis.
                {
                  subvolume = "/var/lib";
                  repo = "${host}:${this}-timelapse";
                  paths = [ "timelapse-r11/videos" ];
                  # Named by exception rather than by glob: the month videos are
                  # whatever is left, so a change of camera name or container
                  # cannot quietly reduce this job to archiving nothing. days/
                  # holds the per-day videos a month is joined from, and a
                  # ".part.mkv" is a render in flight.
                  exclude = [
                    "timelapse-r11/videos/days"
                    "timelapse-r11/videos/.*.part.mkv"
                  ];
                  compression = "none";
                  chunkerParams = "buzhash,19,23,22,4095";
                  prune.keep = {
                    within = "10y";
                    last = 3;
                  };
                  backup_at = "*-*-* 03:00:01 UTC";
                }
                # 197k files of which one changes a night, so 593 archives cost
                # 2.8 GB between them. Thinning them to a daily/weekly/monthly
                # ladder would reclaim 2.4 GB and charge a hundred million item
                # refcount decrements for it, then a slice of that every night
                # forever. Keeping everything is both cheaper and better.
                {
                  subvolume = "/home";
                  # Not a new repository on either destination: both keep the
                  # contents they already had, rewrapped by hand onto the
                  # passphrase the rest of them use. That costs nothing -- borg
                  # re-encrypts the stored key and leaves every chunk alone.
                  repo = "${host}:${this}-home-motiejus-annex2";
                  paths = [ "motiejus/annex2" ];
                  # The module default chunker, 64 KiB, measured 0.78 GB (5.1%)
                  # smaller here than 4 MiB -- all of it deduplication between
                  # 107k Maildir messages, none of it the photos.
                  prune.keep = {
                    within = "10y";
                    last = 3;
                  };
                  backup_at = "*-*-* 02:30:01 UTC";
                }
              ])
              [
                rsync-net
                vno3-nk
              ];

        };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/home";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/home";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
          }
          {
            subvolume = "/var/lib";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
        ];
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };

      matrix-synapse = {
        enable = true;
        signingKeyPath = config.age.secrets.synapse-jakstys-signing-key.path;
        registrationSharedSecretPath = config.age.secrets.synapse-registration-shared-secret.path;
        macaroonSecretKeyPath = config.age.secrets.synapse-macaroon-secret-key.path;
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:config.git";
          deployDerivations = [
            ".#fwminex"
            ".#fra1-c"
          ];
          deployIfPresent = [
            {
              derivationTarget = ".#vno3-nk";
              pingTarget = "vno3-nk.jakst.vpn";
            }
            {
              derivationTarget = ".#vno1-gdrx";
              pingTarget = "vno1-gdrx.jakst.vpn";
            }
            {
              derivationTarget = ".#vno2-desk2";
              pingTarget = "vno2-desk2.jakst.vpn";
            }
          ];
        };

        follower = {
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [ tailscale.sshPattern ];
        };
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

    };
  };

  environment = {
    enableDebugInfo = true;
    systemPackages = with pkgs; [
      stagit
      yt-dlp
      tpm2-tools
      amdgpu_top
      graphicsmagick
      ffmpeg_7-headless # Pin to FFmpeg 7 due to FFmpeg 8 RTSP issues
      age-plugin-yubikey

      # timelapse-archive.service drives these nightly; here for running a
      # single period by hand
      timelapse-merger
      timelapse-videomaker
      timelapse-daily
      timelapse-reap
    ];
  };

  networking = {
    hostId = "a6b19da0";
    hostName = "fwminex";
    domain = "jakst.vpn";
    firewall = {
      rejectPackets = true;
      allowedUDPPorts = [
        53
        80
        443
        8443
      ];
      allowedTCPPorts = [
        53
        80
        443
        8443
      ];
    };
  };
}

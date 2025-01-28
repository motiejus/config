{
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
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-server-passwd-hash.file = ../../secrets/motiejus_server_passwd_hash.age;
    root-server-passwd-hash.file = ../../secrets/root_server_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    borgbackup-password.file = ../../secrets/fwminex/borgbackup-password.age;
    letsencrypt-account-key.file = ../../secrets/letsencrypt/account.key.age;
    vaultwarden-secrets-env.file = ../../secrets/vaultwarden/secrets.env.age;
    synapse-jakstys-signing-key.file = ../../secrets/synapse/jakstys_lt_signing_key.age;
    synapse-registration-shared-secret.file = ../../secrets/synapse/registration_shared_secret.age;
    synapse-macaroon-secret-key.file = ../../secrets/synapse/macaroon_secret_key.age;
    syncthing-key.file = ../../secrets/fwminex/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/fwminex/syncthing/cert.pem.age;
    frigate.file = ../../secrets/frigate.age;
    r1-htpasswd = {
      file = ../../secrets/r1-htpasswd.age;
      owner = "nginx";
    };

    ssh8022-server = {
      file = ../../secrets/ssh8022.age;
      owner = "spiped";
      path = "/var/lib/spiped/ssh8022.key";
    };
  };

  boot = {
    loader.systemd-boot.enable = true;
    initrd = {
      systemd.enable = true;
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
        };
      };
    };
  };

  swapDevices = [
    {
      device = "${nvme}-part2";
      randomEncryption.enable = true;
    }
  ];

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luksroot";
      fsType = "btrfs";
      options = [ "compress=zstd" ];
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "vfat";
    };
  };

  hardware = {
    cpu.intel.updateMicrocode = true;
    graphics = {
      enable = true;
      extraPackages = [ pkgs.intel-media-driver ];
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  systemd = {
    tmpfiles.rules = [ "d /var/www 0755 motiejus users -" ];

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

      frigate = {
        preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/frigate/secrets.env";
        serviceConfig = {
          EnvironmentFile = [ "-/run/frigate/secrets.env" ];
          RuntimeDirectory = "frigate";
          LoadCredential = [ "secrets.env:${config.age.secrets.frigate.path}" ];
        };
      };

      nginx =
        let
          r1 = config.mj.services.nsd-acme.zones."r1.jakstys.lt";
        in
        {
          serviceConfig.LoadCredential = [
            "r1.jakstys.lt-cert.pem:${r1.certFile}"
            "r1.jakstys.lt-key.pem:${r1.keyFile}"
          ];
          after = [ "nsd-acme-r1.jakstys.lt.service" ];
          requires = [ "nsd-acme-r1.jakstys.lt.service" ];
        };

      caddy =
        let
          r1 = config.mj.services.nsd-acme.zones."r1.jakstys.lt";
          irc = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
          grafana = config.mj.services.nsd-acme.zones."grafana.jakstys.lt";
          bitwarden = config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt";
        in
        {
          serviceConfig.LoadCredential = [
            "r1.jakstys.lt-cert.pem:${r1.certFile}"
            "r1.jakstys.lt-key.pem:${r1.keyFile}"
            "irc.jakstys.lt-cert.pem:${irc.certFile}"
            "irc.jakstys.lt-key.pem:${irc.keyFile}"
            "grafana.jakstys.lt-cert.pem:${grafana.certFile}"
            "grafana.jakstys.lt-key.pem:${grafana.keyFile}"
            "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
            "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
          ];
          after = [
            "nsd-acme-r1.jakstys.lt.service"
            "nsd-acme-irc.jakstys.lt.service"
            "nsd-acme-grafana.jakstys.lt.service"
            "nsd-acme-bitwarden.jakstys.lt.service"
          ];
          requires = [
            "nsd-acme-r1.jakstys.lt.service"
            "nsd-acme-irc.jakstys.lt.service"
            "nsd-acme-grafana.jakstys.lt.service"
            "nsd-acme-bitwarden.jakstys.lt.service"
          ];
        };

      soju =
        let
          acme = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
        in
        {
          serviceConfig = {
            RuntimeDirectory = "soju";
            LoadCredential = [
              "irc.jakstys.lt-cert.pem:${acme.certFile}"
              "irc.jakstys.lt-key.pem:${acme.keyFile}"
            ];
          };
          preStart = ''
            ln -sf $CREDENTIALS_DIRECTORY/irc.jakstys.lt-cert.pem /run/soju/cert.pem
            ln -sf $CREDENTIALS_DIRECTORY/irc.jakstys.lt-key.pem /run/soju/key.pem
          '';
          after = [ "nsd-acme-irc.jakstys.lt.service" ];
          requires = [ "nsd-acme-irc.jakstys.lt.service" ];
        };

      cert-watcher = {
        description = "Restart caddy when tls keys/certs change";
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          StartLimitIntervalSec = 10;
          StartLimitBurst = 5;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart caddy.service";
        };
      };

    };

    paths = {
      cert-watcher = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = [
            config.mj.services.nsd-acme.zones."r1.jakstys.lt".certFile
            config.mj.services.nsd-acme.zones."irc.jakstys.lt".certFile
            config.mj.services.nsd-acme.zones."grafana.jakstys.lt".certFile
            config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt".certFile
          ];
          Unit = "cert-watcher.service";
        };
      };
    };
  };

  services = {
    pcscd.enable = true;
    acpid.enable = true;
    fwupd.enable = true;
    logind = {
      lidSwitch = "ignore";
      powerKey = "suspend";
      powerKeyLongPress = "poweroff";
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

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      globalConfig = ''
        servers {
          metrics
        }
      '';
      virtualHosts = {
        "vpn.jakstys.lt".extraConfig = ''reverse_proxy 127.0.0.1:${toString myData.ports.headscale}'';
        "hass.jakstys.lt:80".extraConfig = ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          reverse_proxy 127.0.0.1:${toString myData.ports.hass}
        '';
        "grafana.jakstys.lt".extraConfig = ''
            @denied not remote_ip ${myData.subnets.tailscale.cidr}
            abort @denied
            reverse_proxy 127.0.0.1:${toString myData.ports.grafana}
          tls {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-key.pem
        '';
        "bitwarden.jakstys.lt".extraConfig = ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          tls {$CREDENTIALS_DIRECTORY}/bitwarden.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/bitwarden.jakstys.lt-key.pem

          # from https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
          encode gzip
          header {
            # Enable HTTP Strict Transport Security (HSTS)
            Strict-Transport-Security "max-age=31536000;"
            # Enable cross-site filter (XSS) and tell browser to block detected attacks
            X-XSS-Protection "1; mode=block"
            # Disallow the site to be rendered within a frame (clickjacking protection)
            X-Frame-Options "SAMEORIGIN"
            Alt-Svc "h3=\":443\"; ma=86400"
          }

          reverse_proxy 127.0.0.1:${toString myData.ports.vaultwarden} {
             header_up X-Real-IP {remote_host}
          }
        '';
        "www.jakstys.lt".extraConfig = ''
          redir https://jakstys.lt
        '';
        "r1.jakstys.lt".extraConfig = ''
          tls {$CREDENTIALS_DIRECTORY}/r1.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/r1.jakstys.lt-key.pem
          redir https://r1.jakstys.lt:8443
        '';
        "irc.jakstys.lt".extraConfig =
          let
            gamja = pkgs.compressDrvWeb (pkgs.gamja.override {
              gamjaConfig = {
                server = {
                  url = "irc.jakstys.lt:6698";
                  nick = "motiejus";
                };
              };
            }) { };
          in
          ''
            @denied not remote_ip ${myData.subnets.tailscale.cidr}
            abort @denied
            tls {$CREDENTIALS_DIRECTORY}/irc.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/irc.jakstys.lt-key.pem

            root * ${gamja}
            file_server browse {
                precompressed zstd br gzip
            }
          '';
        "dl.jakstys.lt".extraConfig = ''
          root * /var/www/dl
          file_server browse {
            hide .stfolder
          }
          encode gzip
        '';
        "jakstys.lt".extraConfig = ''
          header {
            Strict-Transport-Security "max-age=15768000"
            Content-Security-Policy "default-src 'self'"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Alt-Svc "h3=\":443\"; ma=86400"

            /_/* Cache-Control "public, max-age=31536000, immutable"
          }

          root * /var/www/jakstys.lt
          file_server {
            precompressed zstd br gzip
          }

          handle /.well-known/carddav {
            redir https://cdav.migadu.com/
          }
          handle /.well-known/caldav {
            redir https://cdav.migadu.com/
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
              reverse_proxy http://127.0.0.1:${toString myData.ports.matrix-synapse}
            }
        '';
      };
    };

    nginx = {
      defaultHTTPListenPort = 8081;
      defaultSSLListenPort = 8443;
      recommendedTlsSettings = true;
      virtualHosts."r1.jakstys.lt" = {
        extraConfig = ''
          satisfy any;
          allow 127.0.0.1;
          allow ::1;
          deny all;
          auth_basic secured;
          auth_basic_user_file ${config.age.secrets.r1-htpasswd.path};
        '';

        addSSL = true;
        sslCertificate = "/run/credentials/nginx.service/r1.jakstys.lt-cert.pem";
        sslCertificateKey = "/run/credentials/nginx.service/r1.jakstys.lt-key.pem";
      };
    };

    frigate = {
      enable = true;
      hostname = "r1.jakstys.lt";
      settings = {
        detectors = {
          #coral = {
          #  type = "edgetpu";
          #  device = "usb";
          #  enabled = false;
          #};
          cpu = {
            type = "cpu";
            enabled = false;
          };
        };
        record = {
          enabled = true;
          retain = {
            days = 7;
            mode = "all";
          };
        };
        cameras = {
          vno4-dome-panorama = {
            enabled = true;
            detect.enabled = false;
            ffmpeg = {
              #hwaccel_args = "preset-vaapi";
              output_args = {
                record = "preset-record-generic-audio-copy";
              };
              inputs = [
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=0";
                  roles = [
                    "audio"
                    "record"
                    #"detect"
                  ];
                }
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=1&subtype=2";
                  roles = [ "detect" ];
                }
              ];
            };
          };
          vno4-dome-ptz = {
            enabled = true;
            detect.enabled = false;
            ffmpeg = {
              output_args = {
                record = "preset-record-generic-audio-copy";
              };
              inputs = [
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=0";
                  roles = [
                    "audio"
                    "record"
                    #"detect"
                  ];
                }
                {
                  path = "rtsp://frigate:{FRIGATE_RTSP_PASSWORD}@192.168.188.10/cam/realmonitor?channel=2&subtype=2";
                  roles = [ "detect" ];
                }
              ];
            };
          };
        };
      };
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
        scrape_interval = "10s";
        evaluation_interval = "1m";
      };

      scrapeConfigs =
        [
          (
            let
              port = toString config.services.prometheus.exporters.ping.port;
              hosts = [
                "fwminex.servers.jakst"
                "vno3-nk.servers.jakst"
                "fra1-b.servers.jakst"
                "vno1-gdrx.motiejus.jakst"
              ];
            in

            {
              job_name = "ping";
              relabel_configs = map (hostname: {
                source_labels = [ "__address__" ];
                regex = "${myData.hosts.${hostname}.jakstIP}:${port}";
                replacement = "${hostname}:${port}";
                target_label = "instance";
              }) hosts;
              static_configs = [ { targets = map (host: "${myData.hosts.${host}.jakstIP}:${port}") hosts; } ];
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
            job_name = "vno1-vinc.vincentas.jakst";
            static_configs = [ { targets = [ "${myData.hosts."vno1-vinc.vincentas.jakst".jakstIP}:9100" ]; } ];
          }
        ]
        ++ map
          (
            let
              port = builtins.toString myData.ports.exporters.node;
            in
            s: {
              job_name = s;
              static_configs = [ { targets = [ "${myData.hosts.${s}.jakstIP}:${port}" ]; } ];
            }
          )
          [
            "fra1-b.servers.jakst"
            "vno3-nk.servers.jakst"
            "fwminex.servers.jakst"
            "mtworx.motiejus.jakst"
            "vno1-gdrx.motiejus.jakst"
          ];
    };

  };

  mj = {
    stateVersion = "24.05";
    timeZone = "Europe/Vilnius";
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
      gitea.enable = true;
      hass.enable = true;
      syncthing-relay.enable = true;

      ping_exporter.enable = true;

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      immich = {
        enable = true;
        bindPaths = {
          "M-Camera" = "/home/motiejus/annex2/M-Camera";
          "Pictures" = "/home/motiejus/annex2/Pictures";
        };
      };

      ssh8022.server = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-server.path;
      };

      borgstor = {
        enable = true;
        dataDir = "/var/lib/borgstor";
        sshKeys = with myData; [
          hosts."vno3-nk.servers.jakst".publicKey
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
      };

      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      headscale = {
        enable = true;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      nsd-acme =
        let
          accountKey = config.age.secrets.letsencrypt-account-key.path;
        in
        {
          enable = true;
          zones = {
            "r1.jakstys.lt".accountKey = accountKey;
            "irc.jakstys.lt".accountKey = accountKey;
            "grafana.jakstys.lt".accountKey = accountKey;
            "bitwarden.jakstys.lt".accountKey = accountKey;
          };
        };

      btrfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        dirs =
          builtins.concatMap
            (
              host:
              let
                prefix = "${host}:${config.networking.hostName}.${config.networking.domain}";
              in
              [
                {
                  subvolume = "/var/lib";
                  repo = "${prefix}-var_lib";
                  paths = [
                    "hass"
                    "gitea"
                    "caddy"
                    "grafana"
                    "headscale"
                    "bitwarden_rs"
                    "matrix-synapse"
                    "private/soju"

                    # https://immich.app/docs/administration/backup-and-restore/
                    "immich/library"
                    "immich/upload"
                    "immich/profile"
                    "postgresql"
                  ];
                  patterns = [ "- gitea/data/repo-archive/" ];
                  backup_at = "*-*-* 01:00:01 UTC";
                }
                {
                  subvolume = "/home";
                  repo = "${prefix}-home-motiejus-annex2";
                  paths = [ "motiejus/annex2" ];
                  backup_at = "*-*-* 02:30:01 UTC";
                }
              ]
            )
            [
              "zh2769@zh2769.rsync.net"
              "borgstor@${myData.hosts."vno3-nk.servers.jakst".jakstIP}"
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

      remote-builder.client =
        let
          host = myData.hosts."fra1-b.servers.jakst";
        in
        {
          enable = true;
          inherit (host) system supportedFeatures;
          hostName = host.jakstIP;
          sshKey = "/etc/ssh/ssh_host_ed25519_key";
        };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [
            ".#fwminex"
            ".#fra1-b"
            ".#vno3-nk"
          ];
          deployIfPresent = [
            {
              derivationTarget = ".#mtworx";
              pingTarget = myData.hosts."mtworx.motiejus.jakst".jakstIP;
            }
            {
              derivationTarget = ".#vno1-gdrx";
              pingTarget = myData.hosts."vno1-gdrx.motiejus.jakst".jakstIP;
            }
          ];
        };

        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [ tailscale.sshPattern ];
        };
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      friendlyport.ports = [
        {
          subnets = [ myData.subnets.tailscale.cidr ];
          udp = [ 443 ];
          tcp = with myData.ports; [
            80
            443
            5000 # todo move to frigate
            soju
            soju-ws
            prometheus
          ];
        }
      ];

    };
  };

  environment = {
    systemPackages = with pkgs; [
      acpi
      yt-dlp
      ffmpeg
      rtorrent
      age-plugin-yubikey
    ];
  };

  networking = {
    hostId = "a6b19da0";
    hostName = "fwminex";
    domain = "servers.jakst";
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

{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = ["nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NX0TA00913P"];
      immutable = false;
      availableKernelModules = [
        "ahci"
        "xhci_pci"
        "nvme"
        "usbhid"
        "sdhci_pci"
        "r8169" # builtin non working
        "r8152" # startech usb-ethernet adapter
      ];
      removableEfi = true;
      kernelParams = [
        "ip=192.168.189.1::192.168.189.4:255.255.255.0:vno1-oh2.jakstys.lt:enp0s21f0u2:off"
      ];
      sshUnlock = {
        enable = true;
        authorizedKeys =
          (builtins.attrValues myData.people_pubkeys)
          ++ [myData.hosts."fra1-a.servers.jakst".publicKey];
      };
    };
  };

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base = {
      zfs.enable = true;
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      snapshot = {
        enable = true;
        mountpoints = ["/home" "/var/lib" "/var/log"];
      };

      zfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        dirs = [
          # TODO merge
          {
            mountpoint = "/var/lib";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "bitwarden_rs"
              "caddy"
              "gitea"
              "grafana"
              "hass"
              "headscale"
              "matrix-synapse"
              "nsd-acme"
              "tailscale"
              "private/soju"
            ];
            patterns = [
              "- gitea/data/repo-archive/"
            ];
            backup_at = "*-*-* 01:00:00 UTC";
            prune.keep = {
              within = "1d";
              daily = 1;
              weekly = 0;
              monthly = 0;
            };
          }
          {
            mountpoint = "/var/lib";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "bitwarden_rs"
              "caddy"
              "gitea"
              "grafana"
              "hass"
              "headscale"
              "matrix-synapse"
              "nsd-acme"
              "tailscale"
              "private/soju"
            ];
            patterns = [
              "- gitea/data/repo-archive/"
            ];
            backup_at = "*-*-* 01:00:00 UTC";
          }

          # TODO: merge
          {
            mountpoint = "/var/log";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-var_log";
            paths = ["caddy"];
            patterns = [
              "+ caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 01:30:00 UTC";
          }
          {
            mountpoint = "/var/log";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-var_log";
            paths = ["caddy"];
            patterns = [
              "+ caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 01:30:00 UTC";
          }

          # TODO merge
          {
            mountpoint = "/home";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [
              "motiejus/annex2"
              "motiejus/.config/syncthing"
            ];
            backup_at = "*-*-* 02:00:00 UTC";
          }
          {
            mountpoint = "/home";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [
              "motiejus/annex2"
              "motiejus/.config/syncthing"
            ];
            backup_at = "*-*-* 02:00:00 UTC";
          }
        ];
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      friendlyport.ports = [
        {
          subnets = [myData.subnets.tailscale.cidr];
          tcp = with myData.ports; [
            80
            443
            grafana
            prometheus
            soju
            soju-ws
          ];
        }
      ];

      tailscale.enable = true;
      node_exporter.enable = true;
      gitea.enable = true;
      sshguard.enable = true;
      hass.enable = true;

      headscale = {
        enable = true;
        clientOidcPath = config.age.secrets.headscale-client-oidc.path;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      nsd-acme = let
        accountKey = config.age.secrets.letsencrypt-account-key.path;
      in {
        enable = true;
        zones = {
          "irc.jakstys.lt".accountKey = accountKey;
          "hdd.jakstys.lt".accountKey = accountKey;
          "hass.jakstys.lt".accountKey = accountKey;
          "grafana.jakstys.lt".accountKey = accountKey;
          "bitwarden.jakstys.lt".accountKey = accountKey;
        };
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [
            ".#vno1-oh2"
            ".#fra1-a"
          ];
          deployIfPresent = [
            {
              derivationTarget = ".#fwminex";
              pingTarget = myData.hosts."fwminex.motiejus.jakst".jakstIP;
            }
            {
              derivationTarget = ".#mtworx";
              pingTarget = myData.hosts."mtworx.motiejus.jakst".jakstIP;
            }
            {
              derivationTarget = ".#vno1-op5p";
              pingTarget = myData.hosts."vno1-op5p.servers.jakst".jakstIP;
            }
            {
              derivationTarget = ".#vno3-rp3b";
              pingTarget = myData.hosts."vno3-rp3b.servers.jakst".jakstIP;
            }
          ];
        };

        follower = {
          inherit (myData.hosts."vno1-oh2.servers.jakst") publicKey;

          enable = true;
          sshAllowSubnets = [myData.subnets.tailscale.sshPattern];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
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

      zfsunlock = {
        enable = true;
        targets."fra1-a.servers.jakst" = let
          host = myData.hosts."fra1-a.servers.jakst";
        in {
          sshEndpoint = host.publicIP;
          pingEndpoint = host.jakstIP;
          remotePubkey = host.initrdPubKey;
          pwFile = config.age.secrets.zfs-passphrase-fra1-a.path;
          startAt = "*-*-* *:00/5:00";
        };
      };

      remote-builder.client = let
        host = myData.hosts."fra1-a.servers.jakst";
      in {
        enable = true;
        inherit (host) system supportedFeatures;
        hostName = host.jakstIP;
        sshKey = "/etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  services = {
    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      globalConfig = ''
        servers {
          metrics
        }
      '';
      virtualHosts = {
        "hass.jakstys.lt".extraConfig = ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          reverse_proxy 127.0.0.1:8123
          tls {$CREDENTIALS_DIRECTORY}/hass.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/hass.jakstys.lt-key.pem
        '';
        "grafana.jakstys.lt".extraConfig = ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          reverse_proxy 127.0.0.1:3000
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
          }

          # deprecated from vaultwarden 1.29.0
          reverse_proxy /notifications/hub 127.0.0.1:${toString myData.ports.vaultwarden_ws}

          reverse_proxy 127.0.0.1:${toString myData.ports.vaultwarden} {
             header_up X-Real-IP {remote_host}
          }
        '';
        "www.jakstys.lt".extraConfig = ''
          redir https://jakstys.lt
        '';
        "irc.jakstys.lt".extraConfig = let
          gamja = pkgs.compressDrvWeb (pkgs.gamja.override {
            gamjaConfig = {
              server = {
                url = "irc.jakstys.lt:6698";
                nick = "motiejus";
              };
            };
          }) {};
        in ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          tls {$CREDENTIALS_DIRECTORY}/irc.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/irc.jakstys.lt-key.pem

          root * ${gamja}
          file_server browse {
              precompressed br gzip
          }
        '';
        "dl.jakstys.lt".extraConfig = ''
          root * /var/www/dl
          file_server browse {
            hide .stfolder
          }
          encode gzip
        '';
        "jakstys.lt" = {
          logFormat = ''
            output file ${config.services.caddy.logDir}/access-jakstys.lt.log {
              roll_disabled
            }
          '';
          extraConfig = ''
            header Strict-Transport-Security "max-age=31536000"

            header /_/* Cache-Control "public, max-age=31536000, immutable"

            root * /var/www/jakstys.lt
            file_server {
              precompressed br gzip
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
    };

    photoprism = {
      enable = true;
      originalsPath = "/data";
      passwordFile = config.age.secrets.photoprism-admin-passwd.path;
    };

    logrotate = {
      settings = {
        "/var/log/caddy/access-jakstys.lt.log" = {
          rotate = -1;
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

    grafana = {
      enable = true;
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString config.services.prometheus.port}";
              isDefault = true;
              jsonData.timeInterval = "10s";
            }
          ];
        };
      };
      settings = {
        paths.logs = "/var/log/grafana";
        server = {
          domain = "grafana.jakstys.lt";
          root_url = "https://grafana.jakstys.lt";
          enable_gzip = true;
          http_addr = "0.0.0.0";
          http_port = myData.ports.grafana;
        };
        users.auto_assign_org = true;
        users.auto_assign_org_role = "Editor";

        # https://github.com/grafana/grafana/issues/70203#issuecomment-1612823390
        auth.oauth_allow_insecure_email_lookup = true;

        "auth.generic_oauth" = {
          enabled = true;
          auto_login = true;
          client_id = "5349c113-467d-4b95-a61b-264f2d844da8";
          client_secret = "$__file{/run/grafana/oidc-secret}";
          auth_url = "https://git.jakstys.lt/login/oauth/authorize";
          api_url = "https://git.jakstys.lt/login/oauth/userinfo";
          token_url = "https://git.jakstys.lt/login/oauth/access_token";
        };
        feature_toggles.accessTokenExpirationCheck = true;
      };
    };

    prometheus = {
      enable = true;
      port = myData.ports.prometheus;
      retentionTime = "1y";

      globalConfig = {
        scrape_interval = "10s";
        evaluation_interval = "1m";
      };

      scrapeConfigs = let
        port = builtins.toString myData.ports.exporters.node;
      in [
        {
          job_name = "prometheus";
          static_configs = [{targets = ["127.0.0.1:${toString myData.ports.prometheus}"];}];
        }
        {
          job_name = "caddy";
          static_configs = [{targets = ["127.0.0.1:${toString myData.ports.exporters.caddy}"];}];
        }
        {
          job_name = "${config.networking.hostName}.${config.networking.domain}";
          static_configs = [{targets = ["127.0.0.1:${port}"];}];
        }
        {
          job_name = "fra1-a.servers.jakst";
          static_configs = [{targets = ["${myData.hosts."fra1-a.servers.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "vno3-rp3b.servers.jakst";
          static_configs = [{targets = ["${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "vno1-op5p.servers.jakst";
          static_configs = [{targets = ["${myData.hosts."vno1-op5p.servers.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "fwminex.motiejus.jakst";
          static_configs = [{targets = ["${myData.hosts."fwminex.motiejus.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "mtworx.motiejus.jakst";
          static_configs = [{targets = ["${myData.hosts."mtworx.motiejus.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "vno1-vinc.vincentas.jakst";
          static_configs = [{targets = ["${myData.hosts."vno1-vinc.vincentas.jakst".jakstIP}:9100"];}];
        }
      ];
    };

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
        "11sync.net.".data = myData.e11syncZone;
      };
    };

    soju = {
      enable = true;
      listen = [
        #"unix+admin://"
        ":${toString myData.ports.soju}"
        "wss://:${toString myData.ports.soju-ws}"
      ];
      tlsCertificate = "/run/soju/cert.pem";
      tlsCertificateKey = "/run/soju/key.pem";
      hostName = "irc.jakstys.lt";
      httpOrigins = ["*"];
      extraConfig = ''
        message-store fs /var/lib/soju
      '';
    };

    vaultwarden = {
      enable = true;

      config = {
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = myData.ports.vaultwarden;
        LOG_LEVEL = "warn";
        DOMAIN = "https://bitwarden.jakstys.lt";
        SIGNUPS_ALLOWED = false;
        INVITATION_ORG_NAME = "jakstys";
        PUSH_ENABLED = true;

        # TODO remove after 1.29.0
        WEBSOCKET_ENABLED = true;
        WEBSOCKET_ADDRESS = "127.0.0.1";
        WEBSOCKET_PORT = myData.ports.vaultwarden_ws;

        SMTP_HOST = "localhost";
        SMTP_PORT = 25;
        SMTP_SECURITY = "off";
        SMTP_FROM = "admin@jakstys.lt";
        SMTP_FROM_NAME = "Bitwarden at jakstys.lt";
      };
    };

    minidlna = {
      enable = true;
      openFirewall = true;
      settings = {
        media_dir = ["/home/motiejus/video"];
        friendly_name = "vno1-oh2";
        inotify = "yes";
      };
    };

    syncthing.relay = {
      enable = true;
      providedBy = "11sync.net";
    };
  };

  systemd.services = {
    caddy = let
      irc = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
      hass = config.mj.services.nsd-acme.zones."hass.jakstys.lt";
      grafana = config.mj.services.nsd-acme.zones."grafana.jakstys.lt";
      bitwarden = config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt";
    in {
      serviceConfig.LoadCredential = [
        "irc.jakstys.lt-cert.pem:${irc.certFile}"
        "irc.jakstys.lt-key.pem:${irc.keyFile}"
        "hass.jakstys.lt-cert.pem:${hass.certFile}"
        "hass.jakstys.lt-key.pem:${hass.keyFile}"
        "grafana.jakstys.lt-cert.pem:${grafana.certFile}"
        "grafana.jakstys.lt-key.pem:${grafana.keyFile}"
        "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
        "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
      ];
      after = [
        "nsd-acme-irc.jakstys.lt.service"
        "nsd-acme-hass.jakstys.lt.service"
        "nsd-acme-grafana.jakstys.lt.service"
        "nsd-acme-bitwarden.jakstys.lt.service"
      ];
      requires = [
        "nsd-acme-irc.jakstys.lt.service"
        "nsd-acme-hass.jakstys.lt.service"
        "nsd-acme-grafana.jakstys.lt.service"
        "nsd-acme-bitwarden.jakstys.lt.service"
      ];
    };

    soju = let
      acme = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
    in {
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
      after = ["nsd-acme-irc.jakstys.lt.service"];
      requires = ["nsd-acme-irc.jakstys.lt.service"];
    };

    vaultwarden = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/vaultwarden/secrets.env";
      serviceConfig = {
        EnvironmentFile = ["-/run/vaultwarden/secrets.env"];
        RuntimeDirectory = "vaultwarden";
        LoadCredential = [
          "secrets.env:${config.age.secrets.vaultwarden-secrets-env.path}"
        ];
      };
    };

    grafana = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/oidc /run/grafana/oidc-secret";
      serviceConfig = {
        LogsDirectory = "grafana";
        RuntimeDirectory = "grafana";
        LoadCredential = ["oidc:${config.age.secrets.grafana-oidc.path}"];
      };
    };

    cert-watcher = {
      description = "Restart caddy when tls keys/certs change";
      wantedBy = ["multi-user.target"];
      unitConfig = {
        StartLimitIntervalSec = 10;
        StartLimitBurst = 5;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart caddy.service";
      };
    };

    minidlna = {
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = ["/home/motiejus/video"];
      };
    };

    syncthing-relay.restartIfChanged = false;

    photoprism.serviceConfig = {
      ProtectHome = lib.mkForce "tmpfs";
      BindPaths = [
        "/home/motiejus/annex2/M-Active:/data/M-Camera"
        "/home/motiejus/annex2/Pictures:/data/Pictures"
      ];
    };
  };

  systemd.paths = {
    cert-watcher = {
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = [
          config.mj.services.nsd-acme.zones."irc.jakstys.lt".certFile
          config.mj.services.nsd-acme.zones."hass.jakstys.lt".certFile
          config.mj.services.nsd-acme.zones."grafana.jakstys.lt".certFile
          config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt".certFile
        ];
        Unit = "cert-watcher.service";
      };
    };
  };

  users = let
    uidgid = myData.uidgid.photoprism;
  in {
    groups.photoprism.gid = uidgid;
    users.photoprism = {
      group = "photoprism";
      uid = uidgid;
    };
  };

  environment.systemPackages = with pkgs; [
    yt-dlp
    imapsync
    geoipWithDatabase
  ];

  networking = {
    hostId = "f9117e1b";
    hostName = "vno1-oh2";
    domain = "servers.jakst";
    defaultGateway = "192.168.189.4";
    nameservers = ["192.168.189.4"];
    interfaces.enp0s21f0u2.ipv4.addresses = [
      {
        address = "192.168.189.1";
        prefixLength = 24;
      }
    ];
    firewall = {
      allowedUDPPorts = [53 80 443];
      allowedTCPPorts = [
        53
        80
        443
        config.services.syncthing.relay.port
        config.services.syncthing.relay.statusPort
      ];
      rejectPackets = true;
    };
  };
}

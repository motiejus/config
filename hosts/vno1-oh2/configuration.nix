{
  config,
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

    base = {
      zfs.enable = true;
      users = {
        devEnvironment = true;
        passwd = {
          root.passwordFile = config.age.secrets.root-passwd-hash.path;
          motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
        };
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
              "headscale"
              "matrix-synapse"
              "nsd-acme"
              "tailscale"
              "private/soju"
            ];
            backup_at = "*-*-* 00:01:00";
          }
          {
            mountpoint = "/var/lib";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "bitwarden_rs"
              "caddy"
              "gitea"
              "grafana"
              "headscale"
              "matrix-synapse"
              "nsd-acme"
              "tailscale"
              "private/soju"
            ];
            backup_at = "*-*-* 00:01:00";
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
            backup_at = "*-*-* 00:02:00";
          }
          {
            mountpoint = "/var/log";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-var_log";
            paths = ["caddy"];
            patterns = [
              "+ caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 00:02:00";
          }

          # TODO merge
          {
            mountpoint = "/home";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [
              "motiejus/annex2"
              "motiejus/.config/syncthing"
            ];
            backup_at = "*-*-* 00:05:00 UTC";
          }
          {
            mountpoint = "/home";
            repo = "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [
              "motiejus/annex2"
              "motiejus/.config/syncthing"
            ];
            backup_at = "*-*-* 00:05:00 UTC";
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
          tcp = [
            80
            443
            myData.ports.grafana
            myData.ports.prometheus
            myData.ports.soju
          ];
        }
      ];
      tailscale.enable = true;
      node_exporter.enable = true;
      gitea.enable = true;
      snmp_exporter.enable = true;
      sshguard.enable = true;

      headscale = {
        enable = true;
        clientOidcPath = config.age.secrets.headscale-client-oidc.path;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      nsd-acme = let
        accountKey = config.age.secrets.letsencrypt-account-key.path;
      in {
        enable = true;
        zones."grafana.jakstys.lt".accountKey = accountKey;
        zones."irc.jakstys.lt".accountKey = accountKey;
        zones."bitwarden.jakstys.lt".accountKey = accountKey;
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [
            ".#vno1-oh2"
            ".#vno3-rp3b"
            ".#fra1-a"
          ];
        };

        follower = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          publicKey = myData.hosts."vno1-oh2.servers.jakst".publicKey;
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
      virtualHosts."grafana.jakstys.lt".extraConfig = ''
        @denied not remote_ip ${myData.subnets.tailscale.cidr}
        abort @denied
        reverse_proxy 127.0.0.1:3000
        tls {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-key.pem
      '';
      virtualHosts."bitwarden.jakstys.lt".extraConfig = ''
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
      virtualHosts."www.jakstys.lt".extraConfig = ''
        redir https://jakstys.lt
      '';
      virtualHosts."dl.jakstys.lt".extraConfig = ''
        root * /var/www/dl
        file_server browse {
          hide .stfolder
        }
        encode gzip
      '';
      virtualHosts."jakstys.lt" = {
        logFormat = ''
          output file ${config.services.caddy.logDir}/access-jakstys.lt.log {
            roll_disabled
          }
        '';
        extraConfig = ''
          header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

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
            reverse_proxy http://127.0.0.1:${toString myData.ports.matrix-synapse}
          }
        '';
      };
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
        users.auto_assign_org_role = "Admin";

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
          job_name = "snmp_exporter";
          static_configs = [{targets = ["127.0.0.1:9116"];}];
        }
        {
          job_name = "snmp-mikrotik";
          static_configs = [
            {
              targets = [
                "192.168.189.2" # kids
                "192.168.189.3" # livingroom
                "192.168.189.4" # commbox
              ];
            }
          ];
          metrics_path = "./snmp";
          params = {
            auth = ["public_v2"];
            module = ["mikrotik"];
          };
          relabel_configs = [
            {
              source_labels = ["__address__"];
              target_label = "__param_target";
            }
            {
              source_labels = ["__param_target"];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "127.0.0.1:9116";
            }
          ];
        }
      ];
    };

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
    };

    soju = {
      enable = true;
      listen = ["unix+admin://" ":${toString myData.ports.soju}"];
      tlsCertificate = "/run/soju/cert.pem";
      tlsCertificateKey = "/run/soju/key.pem";
      hostName = "irc.jakstys.lt";
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
  };

  systemd.services = {
    caddy = let
      grafana = config.mj.services.nsd-acme.zones."grafana.jakstys.lt";
      bitwarden = config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt";
    in {
      serviceConfig.LoadCredential = [
        "grafana.jakstys.lt-cert.pem:${grafana.certFile}"
        "grafana.jakstys.lt-key.pem:${grafana.keyFile}"
        "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
        "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
      ];
      after = [
        "nsd-acme-grafana.jakstys.lt.service"
        "nsd-acme-bitwarden.jakstys.lt.service"
      ];
      requires = [
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
  };

  systemd.paths = {
    cert-watcher = {
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = [
          config.mj.services.nsd-acme.zones."grafana.jakstys.lt".certFile
          config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt".certFile
        ];
        Unit = "cert-watcher.service";
      };
    };
  };

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
      allowedTCPPorts = [53 80 443];
    };
  };
}

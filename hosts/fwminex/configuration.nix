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
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-server-passwd-hash.file = ../../secrets/motiejus_server_passwd_hash.age;
    root-server-passwd-hash.file = ../../secrets/root_server_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    borgbackup-password.file = ../../secrets/${config.networking.hostName}/borgbackup-password.age;
    letsencrypt-account-key.file = ../../secrets/letsencrypt/account.key.age;
    vaultwarden-secrets-env.file = ../../secrets/vaultwarden/secrets.env.age;
    synapse-jakstys-signing-key.file = ../../secrets/synapse/jakstys_lt_signing_key.age;
    synapse-registration-shared-secret.file = ../../secrets/synapse/registration_shared_secret.age;
    synapse-macaroon-secret-key.file = ../../secrets/synapse/macaroon_secret_key.age;
    syncthing-key.file = ../../secrets/fwminex/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/fwminex/syncthing/cert.pem.age;
    frigate.file = ../../secrets/frigate.age;
    timelapse.file = ../../secrets/timelapse.age;
    plik.file = ../../secrets/fwminex/up.jakstys.lt.env.age;
    r1-htpasswd = {
      file = ../../secrets/r1-htpasswd.age;
      owner = "nginx";
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
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          keyFileOffset = 9728;
          keyFileSize = 512;
          keyFile = "/dev/sda";
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
          preStart = "ln -sf $CREDENTIALS_DIRECTORY/up.jakstys.lt.env /run/caddy/up.jakstys.lt.env";
          serviceConfig = {
            LoadCredential = [
              "r1.jakstys.lt-cert.pem:${r1.certFile}"
              "r1.jakstys.lt-key.pem:${r1.keyFile}"
              "irc.jakstys.lt-cert.pem:${irc.certFile}"
              "irc.jakstys.lt-key.pem:${irc.keyFile}"
              "grafana.jakstys.lt-cert.pem:${grafana.certFile}"
              "grafana.jakstys.lt-key.pem:${grafana.keyFile}"
              "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
              "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
              "up.jakstys.lt.env:${config.age.secrets.plik.path}"
            ];
            RuntimeDirectory = "caddy";
            EnvironmentFile = [ "-/run/caddy/up.jakstys.lt.env" ];
          };
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
        description = "Restart nginx+caddy when tls keys/certs change";
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          StartLimitIntervalSec = 10;
          StartLimitBurst = 5;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart --no-block nginx.service caddy.service";
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

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      globalConfig = ''
        grace_period 1s
        metrics {
          per_host
        }
      '';
      virtualHosts = {
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
        "up.jakstys.lt".extraConfig = ''
          basic_auth {
            {$PLIK_USER} {$PLIK_PASSWORD}
          }
          reverse_proxy 127.0.0.1:${toString myData.ports.plik}
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
        "r.jakstys.lt".extraConfig = ''
          redir https://rita.jakstys.lt{uri} 301
        '';
        "rita.jakstys.lt".extraConfig = ''
          root * /var/www/rita.jakstys.lt
          file_server {
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
        "m.jakstys.lt".extraConfig = ''
          header {
            Strict-Transport-Security "max-age=15768000"
            Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Alt-Svc "h3=\":443\"; ma=86400"
            /_/* Cache-Control "public, max-age=31536000, immutable"
          }

          root * /var/www/m.jakstys.lt
          file_server {
            precompressed zstd br gzip
          }
        '';
        "jakstys.lt".extraConfig =
          let
            jakstysLandingPage =
              pkgs.runCommand "jakstys-landing-page"
                {
                  nativeBuildInputs = with pkgs; [
                    zstd
                    brotli
                    zopfli
                  ];
                }
                ''
                  mkdir -p $out
                  cp ${../../jakstys.lt/index.html} $out/index.html
                  cp ${../../jakstys.lt/robots.txt} $out/robots.txt
                  cp ${../../jakstys.lt/robots.txt} $out/googlebfa9b278b6db80a4.html
                  OUTS=(index.html robots.txt googlebfa9b278b6db80a4.html)
                  for outfile in "''${OUTS[@]}"; do
                    zstd -k -19 "$out/$outfile"
                    brotli -k "$out/$outfile"
                    zopfli -k "$out/$outfile"
                  done
                '';
          in
          ''
            @redirects {
              path /2022/big-tech-hiring/
              path /2022/first-post-here/
              path /2022/how-uber-uses-zig/
              path /2022/my-favorite-podcast/
              path /2022/side-project-retrospective/
              path /2022/smart-bundling/
              path /2022/synctech.html
              path /2022/startup/
              path /2022/uber-mock-interview-retrospective/
              path /2023/7-years-at-uber/
              path /2023/end-of-summer-2023/
              path /2023/microsoft-git/
              path /2023/my-declining-matrix-usage/
              path /2023/my-zig-and-go-work-for-the-next-3-months/
              path /2023/nixos-subjectively/
              path /2023/summer-roadmap-2023/
              path /2024/11sync-shutdown/
              path /2024/11sync-signup/
              path /2024/bcachefs/
              path /2024/family-single-sign-on-was-a-bad-idea/
              path /2024/i-have-successfully-re-googled-myself/
              path /2024/new-job/
              path /2024/thank-you-drew-devault/
              path /2024/web-compression/
              path /2024/zig-reproduced-without-binaries/
              path /2025/construction-site-surveillance/
              path /2026/testing-lifepo4-15ah-with-gyrfalcon-s8000/
              path /contact/
              path /gpg.txt
              path /log/rss.xml
              path /resume/
              path /resume.pdf
              path /talks/
              path /talks/2016-buildstuff-understanding-building-your-own-docker.mkv
              path /talks/2016-buildstuff-understanding-building-your-own-docker.pdf
              path /talks/2022-zig-milan-party_How-zig-is-used-at-Uber.pdf
              path /talks/2022-zig-milan-party_How-zig-is-used-at-Uber.webm
              path /talks/2024-sycl-maps-and-yellow-pages.mkv
              path /talks/2024-sycl-maps-and-yellow-pages.pdf
            }

            header {
              Strict-Transport-Security "max-age=15768000"
              Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'"
              X-Content-Type-Options "nosniff"
              X-Frame-Options "DENY"
              Alt-Svc "h3=\":443\"; ma=86400"

              /_/* Cache-Control "public, max-age=31536000, immutable"
            }

            root * ${jakstysLandingPage}
            file_server {
              precompressed zstd br gzip
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

            redir @redirects https://m.jakstys.lt{uri} 302
          '';
      };
    };

    nginx = {
      defaultHTTPListenPort = 8081;
      defaultSSLListenPort = 8443;
      recommendedTlsSettings = true;
      virtualHosts."r1.jakstys.lt" = {
        extraConfig = ''
          error_page 497 301 =307 https://$host:$server_port$request_uri;
          auth_basic secured;
          auth_basic_user_file ${config.age.secrets.r1-htpasswd.path};
        '';

        addSSL = true;
        sslCertificate = "/run/credentials/nginx.service/r1.jakstys.lt-cert.pem";
        sslCertificateKey = "/run/credentials/nginx.service/r1.jakstys.lt-key.pem";
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
            "mtworx.jakst.vpn"
            "vno1-gdrx.jakst.vpn"
            "vno2-desk2.jakst.vpn"
          ];
    };

  };

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
      gitea.enable = true;
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
        onCalendar = "*-*-* *:0/5:00";
        secretsEnv = config.age.secrets.timelapse.path;
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
      };

      tailscale = {
        enable = true;
        verboseLogs = false;
        acceptDNS = true;
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

      btrfsborg =
        let
          this = "${config.networking.hostName}.${config.networking.domain}";
          vno3-nk = "borgstor@vno3-nk.jakst.vpn";
          rsync-net = "zh2769@zh2769.rsync.net";
        in
        {
          enable = true;
          passwordPath = config.age.secrets.borgbackup-password.path;
          sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
          dirs = [
            {
              subvolume = "/var/lib";
              repo = "${vno3-nk}:${this}-var_lib_lesser";
              paths = [
                "prometheus2"
                "private/timelapse-r11"
              ];
              backup_at = "*-*-* 02:01:00 UTC";
              compression = "none";
            }
          ]
          ++ (builtins.concatMap
            (host: [
              {
                subvolume = "/var/lib";
                repo = "${host}:${this}-var_lib";
                paths = [
                  "hass"
                  "gitea"
                  "caddy"
                  "grafana"
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
                repo = "${host}:${this}-home-motiejus-annex2";
                paths = [ "motiejus/annex2" ];
                backup_at = "*-*-* 02:30:01 UTC";
              }
            ])
            [
              rsync-net
              vno3-nk
            ]
          );
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
          repo = "git@git.jakstys.lt:motiejus/config";
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
              derivationTarget = ".#mtworx";
              pingTarget = "mtworx.jakst.vpn";
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
      yt-dlp
      inferno
      tpm2-tools
      amdgpu_top
      graphicsmagick
      ffmpeg_7-headless # Pin to FFmpeg 7 due to FFmpeg 8 RTSP issues
      age-plugin-yubikey
      (python3.withPackages (
        ps: with ps; [
          ipython
        ]
      ))
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

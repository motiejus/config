{
  config,
  pkgs,
  myData,
  ...
}:
{
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = [ "nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NX0TA00913P" ];
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
    };
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

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
        mountpoints = [
          "/home"
          "/var/lib"
          "/var/log"
        ];
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
              "hass"
              "nsd-acme"
              "tailscale"
              "private/soju"
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
            repo = "borgstor@${
              myData.hosts."vno3-rp3b.servers.jakst".jakstIP
            }:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "bitwarden_rs"
              "caddy"
              "hass"
              "nsd-acme"
              "tailscale"
              "private/soju"
            ];
            backup_at = "*-*-* 01:00:00 UTC";
          }

          # TODO: merge
          {
            mountpoint = "/var/log";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-var_log";
            paths = [ "caddy" ];
            patterns = [
              "+ caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 01:30:00 UTC";
          }
          {
            mountpoint = "/var/log";
            repo = "borgstor@${
              myData.hosts."vno3-rp3b.servers.jakst".jakstIP
            }:${config.networking.hostName}.${config.networking.domain}-var_log";
            paths = [ "caddy" ];
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
            paths = [ "motiejus/annex2" ];
            backup_at = "*-*-* 02:00:00 UTC";
          }
          {
            mountpoint = "/home";
            repo = "borgstor@${
              myData.hosts."vno3-rp3b.servers.jakst".jakstIP
            }:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [ "motiejus/annex2" ];
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
          subnets = [ myData.subnets.tailscale.cidr ];
          tcp = with myData.ports; [
            80
            443
            soju
            soju-ws
          ];
        }
      ];

      tailscale.enable = true;
      node_exporter.enable = true;
      sshguard.enable = true;
      hass.enable = true;

      nsd-acme =
        let
          accountKey = config.age.secrets.letsencrypt-account-key.path;
        in
        {
          enable = true;
          zones = {
            "irc.jakstys.lt".accountKey = accountKey;
            "hdd.jakstys.lt".accountKey = accountKey;
            "bitwarden.jakstys.lt".accountKey = accountKey;
          };
        };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
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
      virtualHosts =
        let
          fwminex-vno1 = myData.hosts."fwminex.servers.jakst".vno1IP;
          fwminex-jakst = myData.hosts."fwminex.servers.jakst".jakstIP;
        in
        {
          "www.11sync.net".extraConfig = "redir https://jakstys.lt/2024/11sync-shutdown/";
          "11sync.net".extraConfig = "redir https://jakstys.lt/2024/11sync-shutdown/";
          "vpn.jakstys.lt".extraConfig = ''reverse_proxy ${fwminex-vno1}:${toString myData.ports.headscale}'';
          "git.jakstys.lt".extraConfig = ''reverse_proxy http://${fwminex-vno1}'';
          "hass.jakstys.lt:80".extraConfig = ''
            @denied not remote_ip ${myData.subnets.tailscale.cidr}
            abort @denied
            reverse_proxy 127.0.0.1:${toString myData.ports.hass}
          '';
          "grafana.jakstys.lt:80".extraConfig = ''
            @denied not remote_ip ${myData.subnets.tailscale.cidr}
            abort @denied
            reverse_proxy ${fwminex-jakst}:${toString myData.ports.grafana}
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

            reverse_proxy 127.0.0.1:${toString myData.ports.vaultwarden} {
               header_up X-Real-IP {remote_host}
            }
          '';
          "www.jakstys.lt".extraConfig = ''
            redir https://jakstys.lt
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

    nsd = {
      enable = true;
      interfaces = [
        "0.0.0.0"
        "::"
      ];
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
      httpOrigins = [ "*" ];
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
        media_dir = [ "/home/motiejus/video" ];
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
    caddy =
      let
        irc = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
        bitwarden = config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt";
      in
      {
        serviceConfig.LoadCredential = [
          "irc.jakstys.lt-cert.pem:${irc.certFile}"
          "irc.jakstys.lt-key.pem:${irc.keyFile}"
          "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
          "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
        ];
        after = [
          "nsd-acme-irc.jakstys.lt.service"
          "nsd-acme-bitwarden.jakstys.lt.service"
        ];
        requires = [
          "nsd-acme-irc.jakstys.lt.service"
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

    vaultwarden = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/vaultwarden/secrets.env";
      serviceConfig = {
        EnvironmentFile = [ "-/run/vaultwarden/secrets.env" ];
        RuntimeDirectory = "vaultwarden";
        LoadCredential = [ "secrets.env:${config.age.secrets.vaultwarden-secrets-env.path}" ];
      };
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

    minidlna = {
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = [ "/home/motiejus/video" ];
      };
    };

    syncthing-relay.restartIfChanged = false;

  };

  systemd.paths = {
    cert-watcher = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = [
          config.mj.services.nsd-acme.zones."irc.jakstys.lt".certFile
          config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt".certFile
        ];
        Unit = "cert-watcher.service";
      };
    };
  };

  environment.systemPackages = with pkgs; [
    yt-dlp
    ffmpeg
    imapsync
    geoipWithDatabase
  ];

  networking = {
    hostId = "f9117e1b";
    hostName = "vno1-oh2";
    domain = "servers.jakst";
    defaultGateway = "192.168.189.4";
    nameservers = [ "192.168.189.4" ];
    interfaces.enp0s21f0u2.ipv4.addresses = [
      {
        address = "192.168.189.1";
        prefixLength = 24;
      }
    ];
    firewall = {
      allowedUDPPorts = [
        53
        80
        443
      ];
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

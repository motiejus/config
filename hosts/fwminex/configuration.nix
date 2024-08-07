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

  boot = {
    kernelModules = [ "kvm-intel" ];
    loader.systemd-boot.enable = true;
    initrd = {
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      systemd.enableTpm2 = true;
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          #crypttabExtraOpts = ["tpm2-device=auto"];
          keyFileOffset = 9728;
          keyFileSize = 512;
          keyFile = "/dev/sda";
        };
      };
    };
  };

  security.tpm2.enable = true;

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

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd = {
    tmpfiles.rules = [ "d /var/www 0755 motiejus users -" ];

    services = {
      caddy =
        let
          irc = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
          grafana = config.mj.services.nsd-acme.zones."grafana.jakstys.lt";
          bitwarden = config.mj.services.nsd-acme.zones."bitwarden.jakstys.lt";
        in
        {
          serviceConfig.LoadCredential = [
            "irc.jakstys.lt-cert.pem:${irc.certFile}"
            "irc.jakstys.lt-key.pem:${irc.keyFile}"
            "grafana.jakstys.lt-cert.pem:${grafana.certFile}"
            "grafana.jakstys.lt-key.pem:${grafana.keyFile}"
            "bitwarden.jakstys.lt-cert.pem:${bitwarden.certFile}"
            "bitwarden.jakstys.lt-key.pem:${bitwarden.keyFile}"
          ];
          after = [
            "nsd-acme-irc.jakstys.lt.service"
            "nsd-acme-grafana.jakstys.lt.service"
            "nsd-acme-bitwarden.jakstys.lt.service"
          ];
          requires = [
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
      extraConfig = ''
        message-store fs /var/lib/soju
      '';
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
        "www.11sync.net".extraConfig = "redir https://jakstys.lt/2024/11sync-shutdown/";
        "11sync.net".extraConfig = "redir https://jakstys.lt/2024/11sync-shutdown/";
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
        "jakstys.lt".extraConfig = ''
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

    prometheus = {
      enable = true;
      port = myData.ports.prometheus;
      retentionTime = "1y";

      globalConfig = {
        scrape_interval = "10s";
        evaluation_interval = "1m";
      };

      scrapeConfigs =
        let
          port = builtins.toString myData.ports.exporters.node;
        in
        [
          {
            job_name = "prometheus";
            static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.prometheus}" ]; } ];
          }
          {
            job_name = "caddy";
            static_configs = [ { targets = [ "127.0.0.1:${toString myData.ports.exporters.caddy}" ]; } ];
          }
          {
            job_name = "vno1-vinc.vincentas.jakst";
            static_configs = [ { targets = [ "${myData.hosts."vno1-vinc.vincentas.jakst".jakstIP}:9100" ]; } ];
          }
        ]
        ++
          map
            (s: {
              job_name = s;
              static_configs = [ { targets = [ "${myData.hosts.${s}.jakstIP}:${port}" ]; } ];
            })
            [
              "fra1-b.servers.jakst"
              "fwminex.servers.jakst"
              "mtworx.motiejus.jakst"
              "vno3-rp3b.servers.jakst"
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
      sshguard.enable = true;
      gitea.enable = true;
      hass.enable = true;
      syncthing-relay.enable = true;

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
        oidcSecretFile = config.age.secrets.grafana-oidc.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      headscale = {
        enable = true;
        clientOidcPath = config.age.secrets.headscale-client-oidc.path;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      photoprism = {
        enable = true;
        uidgid = myData.uidgid.photoprism;
        paths = {
          "M-Camera" = "/home/motiejus/annex2/M-Active";
          "Pictures" = "/home/motiejus/annex2/Pictures";
        };
        passwordFile = config.age.secrets.photoprism-admin-passwd.path;
      };

      nsd-acme =
        let
          accountKey = config.age.secrets.letsencrypt-account-key.path;
        in
        {
          enable = true;
          zones = {
            "irc.jakstys.lt".accountKey = accountKey;
            "hdd.jakstys.lt".accountKey = accountKey;
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
                    "private/photoprism"
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
              "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}"
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
          {
            subvolume = "/var/lib";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
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

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [
            ".#fwminex"
            ".#fra1-b"
            ".#vno3-rp3b"
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
          tcp = with myData.ports; [
            80
            443
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
      imapsync
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
      ];
      allowedTCPPorts = [
        53
        80
        443
      ];
    };
  };
}

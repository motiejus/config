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
      availableKernelModules = ["ahci" "xhci_pci" "nvme" "usbhid" "sdhci_pci" "r8169"];
      removableEfi = true;
      kernelParams = [
        "ip=192.168.189.1::192.168.189.4:255.255.255.0:vno1-oh2.jakstys.lt:enp3s0:off"
      ];
      sshUnlock = {
        enable = true;
        authorizedKeys =
          (builtins.attrValues myData.people_pubkeys)
          ++ [myData.hosts."hel1-a.servers.jakst".publicKey];
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
        mountpoints = ["/home" "/var/lib"];
      };

      zfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        mountpoints = {
          "/var/lib" = {
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "/var/lib/.snapshot-latest/private/soju"
              "/var/lib/.snapshot-latest/gitea"
              "/var/lib/.snapshot-latest/grafana"
              "/var/lib/.snapshot-latest/matrix-synapse"
            ];
            backup_at = "*-*-* 00:01:00";
          };
          "/home" = {
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-home-motiejus-annex2";
            paths = [
              "/home/.snapshot-latest/motiejus/annex2"
              "/home/.snapshot-latest/motiejus/.config/syncthing"
            ];
            backup_at = "*-*-* 00:05:00 UTC";
          };
        };
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      friendlyport.vpn.ports = [
        80
        443
        myData.ports.grafana
        myData.ports.prometheus
        myData.ports.soju
        myData.ports.matrix-synapse
      ];

      node_exporter.enable = true;

      gitea.enable = true;

      nsd-acme = {
        enable = true;
        zones."grafana.jakstys.lt" = {
          accountKey = config.age.secrets.letsencrypt-account-key.path;
          staging = false;
        };
        zones."irc.jakstys.lt" = {
          accountKey = config.age.secrets.letsencrypt-account-key.path;
          staging = false;
        };
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [".#vno1-oh2" ".#hel1-a" ".#vno1-rp3b"];
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
        targets."hel1-a.servers.jakst" = let
          host = myData.hosts."hel1-a.servers.jakst";
        in {
          sshEndpoint = host.publicIP;
          pingEndpoint = host.jakstIP;
          remotePubkey = host.initrdPubKey;
          pwFile = config.age.secrets.zfs-passphrase-hel1-a.path;
          startAt = "*-*-* *:00/5:00";
        };
      };
    };
  };

  services = {
    tailscale.enable = true;

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      virtualHosts."grafana.jakstys.lt" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:3000
          tls {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-cert.pem {$CREDENTIALS_DIRECTORY}/grafana.jakstys.lt-key.pem
        '';
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
            }
          ];
        };
      };
      settings = {
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

      globalConfig = {
        scrape_interval = "15s";
        evaluation_interval = "15s";
      };

      scrapeConfigs = let
        port = builtins.toString myData.ports.exporters.node;
      in [
        {
          job_name = "${config.networking.hostName}.${config.networking.domain}";
          static_configs = [{targets = ["127.0.0.1:${port}"];}];
        }
        {
          job_name = "hel1-a.servers.jakst";
          static_configs = [{targets = ["${myData.hosts."hel1-a.servers.jakst".jakstIP}:${port}"];}];
        }
        {
          job_name = "vno1-rp3b.servers.jakst";
          static_configs = [{targets = ["${myData.hosts."vno1-rp3b.servers.jakst".jakstIP}:${port}"];}];
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
  };

  systemd.services = {
    caddy = let
      acme = config.mj.services.nsd-acme.zones."grafana.jakstys.lt";
    in {
      serviceConfig.LoadCredential = [
        "grafana.jakstys.lt-cert.pem:${acme.certFile}"
        "grafana.jakstys.lt-key.pem:${acme.keyFile}"
      ];
      after = ["nsd-acme-grafana.jakstys.lt.service"];
      requires = ["nsd-acme-grafana.jakstys.lt.service"];
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

    grafana = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/oidc /run/grafana/oidc-secret";
      serviceConfig = {
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
  };

  systemd.paths = {
    cert-watcher = {
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = [
          config.mj.services.nsd-acme.zones."grafana.jakstys.lt".certFile
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
    interfaces.enp3s0.ipv4.addresses = [
      {
        address = "192.168.189.1";
        prefixLength = 24;
      }
    ];
    firewall = {
      allowedUDPPorts = [53 80 443];
      allowedTCPPorts = [53 80 443];
      checkReversePath = "loose"; # for tailscale
    };
  };
}

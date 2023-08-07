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

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";

    base = {
      zfs.enable = true;
      users.passwd = {
        root.passwordFile = config.age.secrets.root-passwd-hash.path;
        motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      snapshot = {
        enable = true;
        mountpoints = ["/home"];
      };

      zfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        mountpoints = {
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
      # TODO move to grafana service lib
      friendlyport.vpn.ports = [
        myData.ports.grafana
        myData.ports.prometheus
        myData.ports.exporters.node
      ];

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [".#vno1-oh2" ".#hel1-a"];
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

      zfsunlock = {
        enable = true;
        targets."hel1-a.servers.jakst" = {
          sshEndpoint = myData.hosts."hel1-a.servers.jakst".publicIP;
          pingEndpoint = "hel1-a.servers.jakst";
          remotePubkey = myData.hosts."hel1-a.servers.jakst".initrdPubKey;
          pwFile = config.age.secrets.zfs-passphrase-hel1-a.path;
          startAt = "*-*-* *:00/5:00";
        };
      };
    };
  };

  services = {
    tailscale.enable = true;

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
          # TODO tailscale service?
          domain = "${config.networking.hostName}.${config.networking.domain}";
          # NB: this was tailscale0 before, now controlled via firewall.
          http_addr = "0.0.0.0";
          http_port = myData.ports.grafana;
        };
      };
    };

    prometheus = {
      enable = true;
      port = myData.ports.prometheus;
      exporters = {
        node = {
          enable = true;
          enabledCollectors = ["systemd" "processes"];
          port = myData.ports.exporters.node;
        };
      };

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
      ];
    };

    nsd = {
      enable = true;
      remoteControl.enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
      extraConfig = ''
        pattern:
          name: "acme"
      '';
    };
  };

  systemd.services.nsd-control-setup = {
    requiredBy = ["nsd.service"];
    before = ["nsd.service"];
    unitConfig.ConditionPathExists = "!/etc/nsd/nsd_control.pem";
    serviceConfig = {
      Type = "oneshot";
      UMask = 0077;
    };
    path = [pkgs.nsd pkgs.openssl];
    script = ''nsd-control-setup'';
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
      allowedUDPPorts = [53];
      allowedTCPPorts = [53];
      logRefusedConnections = false;
      checkReversePath = "loose"; # for tailscale
    };
  };
}

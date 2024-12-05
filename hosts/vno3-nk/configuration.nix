{
  pkgs,
  config,
  myData,
  ...
}:
let
  disk = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S754NX0W731206W";
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
        "ahci"
        "usbhid"
        "tpm_tis"
      ];
      luks.devices = {
        luksroot = {
          device = "${disk}-part3";
          allowDiscards = true;
        };
      };
    };
  };

  swapDevices = [
    {
      device = "${disk}-part2";
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
      device = "${disk}-part1";
      fsType = "vfat";
    };
  };

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  services = {
    pcscd.enable = true;
    acpid.enable = true;
    fwupd.enable = true;
  };

  mj = {
    stateVersion = "24.11";
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
      ping_exporter.enable = true;

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno3.cidr ];
      };

      #ssh8022.server = {
      #  enable = true;
      #  keyfile = config.age.secrets.ssh8022-server.path;
      #};

      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      #btrfsborg = {
      #  enable = true;
      #  passwordPath = config.age.secrets.borgbackup-password.path;
      #  sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
      #  dirs =
      #    builtins.concatMap
      #      (
      #        host:
      #        let
      #          prefix = "${host}:${config.networking.hostName}.${config.networking.domain}";
      #        in
      #        [
      #          {
      #            subvolume = "/var/lib";
      #            repo = "${prefix}-var_lib";
      #            paths = [
      #              "hass"
      #              "gitea"
      #              "caddy"
      #              "grafana"
      #              "headscale"
      #              "bitwarden_rs"
      #              "matrix-synapse"
      #              "private/soju"

      #              # https://immich.app/docs/administration/backup-and-restore/
      #              "immich/library"
      #              "immich/upload"
      #              "immich/profile"
      #              "postgresql"
      #            ];
      #            patterns = [ "- gitea/data/repo-archive/" ];
      #            backup_at = "*-*-* 01:00:01 UTC";
      #          }
      #          {
      #            subvolume = "/home";
      #            repo = "${prefix}-home-motiejus-annex2";
      #            paths = [ "motiejus/annex2" ];
      #            backup_at = "*-*-* 02:30:01 UTC";
      #          }
      #        ]
      #      )
      #      [
      #        "zh2769@zh2769.rsync.net"
      #      ];
      #};

      #btrfssnapshot = {
      #  enable = true;
      #  subvolumes = [
      #    {
      #      subvolume = "/home";
      #      label = "hourly";
      #      keep = 24;
      #      refreshInterval = "*:00:00";
      #    }
      #    {
      #      subvolume = "/home";
      #      label = "nightly";
      #      keep = 7;
      #      refreshInterval = "daily UTC";
      #    }
      #    {
      #      subvolume = "/var/lib";
      #      label = "hourly";
      #      keep = 24;
      #      refreshInterval = "*:00:00";
      #    }
      #    {
      #      subvolume = "/var/lib";
      #      label = "nightly";
      #      keep = 7;
      #      refreshInterval = "daily UTC";
      #    }
      #  ];
      #};

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

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      #friendlyport.ports = [
      #  {
      #    subnets = [ myData.subnets.tailscale.cidr ];
      #    udp = [ 443 ];
      #    tcp = with myData.ports; [
      #      80
      #      443
      #      prometheus
      #    ];
      #  }
      #];

      #jakstpub = {
      #  enable = true;
      #  dataDir = "/home/motiejus/annex2/vno3-shared";
      #  #requires = [ "data-shared.mount" ];
      #  uidgid = myData.uidgid.jakstpub;
      #  hostname = "hdd.jakstys.lt";
      #};

    };
  };

  environment = {
    systemPackages =
      with pkgs;
      [
      ];
  };

  networking = {
    hostName = "vno3-nk";
    domain = "servers.jakst";
    firewall = {
      rejectPackets = true;
      allowedUDPPorts = [
        80
        443
      ];
      allowedTCPPorts = [
        80
        443
      ];
    };
  };
}
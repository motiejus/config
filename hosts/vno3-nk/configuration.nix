{
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
    borgbackup-password.file = ../../secrets/fwminex/borgbackup-password.age;
    timelapse.file = ../../secrets/timelapse.age;
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

      timelapse-r11 = {
        enable = true;
        onCalendar = "*:0/5:30"; # 30'th second every 5 mins
        secretsEnv = config.age.secrets.timelapse.path;
      };

      ssh8022.server = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-server.path;
      };

      borgstor = {
        enable = true;
        dataDir = "/data/borg";
        sshKeys = with myData; [
          hosts."fwminex.jakst.vpn".publicKey
          people_pubkeys.motiejus
        ];
      };

      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      btrfsborg =
        let
          this = "${config.networking.hostName}.${config.networking.domain}";
          rsync-net = "zh2769@zh2769.rsync.net";
          fwminex = "borgstor@${myData.hosts."fwminex.jakst.vpn".jakstIP}";
        in
        {
          enable = true;
          passwordPath = config.age.secrets.borgbackup-password.path;
          sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
          dirs =
            #[
            #{
            #  subvolume = "/data";
            #  repo = "${fwminex}:${this}-timelapse-r11";
            #  paths = [ "timelapse-r11" ];
            #  backup_at = "*-*-* 02:01:00 UTC";
            #  compression = "none";
            #}
            #] ++ (
            builtins.concatMap
              (
                host:
                let
                  prefix = "${host}:${this}";
                in
                [
                  {
                    subvolume = "/data";
                    repo = "${prefix}-data";
                    paths = [ "vno3-shared" ];
                    backup_at = "*-*-* 01:00:01 UTC";
                  }
                ]
              )
              [
                rsync-net
                fwminex
              ];
          #);
        };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/data";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/data";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
          }
        ];
      };

      remote-builder.client =
        let
          host = myData.hosts."fra1-b.jakst.vpn";
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

      deployerbot = {
        follower = {
          enable = true;
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      jakstpub = {
        enable = true;
        dataDir = "/data/vno3-shared";
        uidgid = myData.uidgid.jakstpub;
        hostname = "hdd.jakstys.lt";
      };

    };
  };

  networking = {
    hostId = "ab4af0bb";
    hostName = "vno3-nk";
    domain = "jakst.vpn";
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

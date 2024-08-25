{
  config,
  pkgs,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-WD_PC_SN810_SDCQNRY-1T00-1201_23234W800017";
in
{
  imports = [
    ../../shared/work
    ../../modules
    ../../modules/profiles/desktop
    ../../modules/profiles/autorandr
    ../../modules/profiles/btrfs
  ];

  age.secrets.ssh8022-client = {
    file = ../../secrets/ssh8022.age;
    owner = "motiejus";
  };

  boot = {
    kernelModules = [ "kvm-intel" ];
    loader.systemd-boot.enable = true;

    # 6.10+ to fix audio. Thanks https://github.com/ilian/cfg/blob/4588b90e674827304cd8e0b9d1aecd75416d1cde/hosts/carbon/configuration.nix#L19
    kernelPackages = pkgs.linuxPackages_6_10;

    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      systemd = {
        enableTpm2 = true;
        emergencyAccess = true;
      };
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          crypttabExtraOpts = [ "tpm2-device=auto" ];
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

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  mj = {
    stateVersion = "23.11";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      devTools = true;
      root.hashedPasswordFile = config.age.secrets.root-work-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-work-passwd-hash.path;
    };

    services = {
      sshguard.enable = false;
      ssh8022.client = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-client.path;

      };

      tailscale = {
        enable = true;
        verboseLogs = true;
      };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/home";
            label = "5minutely";
            keep = 12;
            refreshInterval = "*:0/5";
          }
          {
            subvolume = "/home";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/home";
            label = "daily";
            keep = 7;
            refreshInterval = "daily UTC";
          }
        ];
      };

      wifibackup = {
        enable = true;
        toPath = "/home/${config.mj.username}/M-Active/.wifi";
        toUser = config.mj.username;
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
          maxJobs = 2;
        };

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [ tailscale.sshPattern ];
        };
      };

      postfix = {
        enable = false;
        #saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };

    };
  };

  users.extraGroups.vboxusers.members = [ "motiejus" ];

  security.tpm2.enable = true;

  networking = {
    hostId = "b14a02aa";
    hostName = "mtworx";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };
}

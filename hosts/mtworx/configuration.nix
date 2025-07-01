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

  age.secrets = {
    motiejus-work-passwd-hash.file = ../../secrets/motiejus_work_passwd_hash.age;
    root-work-passwd-hash.file = ../../secrets/root_work_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;

    syncthing-key.file = ../../secrets/mtworx/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/mtworx/syncthing/cert.pem.age;
    kolide-launcher.file = ../../secrets/mtworx/kolide-launcher.age;

    ssh8022-client = {
      file = ../../secrets/ssh8022.age;
      mode = "444";
    };
  };

  boot = {
    kernelPackages = pkgs.linuxPackages_6_12;

    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      systemd.emergencyAccess = true;
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

  hardware.coral.usb.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  mj = {
    stateVersion = "23.11";
    timeZone = "UTC";
    username = "motiejus";

    base.users = {
      enable = true;
      devTools = true;
      root.hashedPasswordFile = config.age.secrets.root-work-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-work-passwd-hash.path;
    };

    services = {
      ssh8022.client = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-client.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
        acceptDNS = true;
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

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];

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

  services = {
    tlp = {
      enable = true;
      settings = {
        START_CHARGE_THRESH_BAT0 = 80;
        STOP_CHARGE_THRESH_BAT0 = 87;
      };
    };
    kolide-launcher.enable = true;
  };

  users.extraGroups.vboxusers.members = [ "motiejus" ];

  environment = {
    systemPackages = with pkgs; [ dnsmasq ];
    etc."kolide-k2/secret" = {
      mode = "600";
      source = config.age.secrets.kolide-launcher.path;
    };
  };

  security.tpm2.enable = true;

  networking = {
    hostId = "b14a02aa";
    hostName = "mtworx";
    domain = "jakst.vpn";
    firewall.rejectPackets = true;
  };
}

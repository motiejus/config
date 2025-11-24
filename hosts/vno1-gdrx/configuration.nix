{
  lib,
  pkgs,
  config,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NX0TA00913P";
  linuxPackage = pkgs.linuxPackages_latest;
in
{
  imports = [
    ../../modules
    ../../modules/profiles/workstation
    ../../modules/profiles/autorandr
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-passwd-hash.file = ../../secrets/motiejus_passwd_hash.age;
    root-passwd-hash.file = ../../secrets/root_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    syncthing-key.file = ../../secrets/vno1-gdrx/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/vno1-gdrx/syncthing/cert.pem.age;

    ssh8022-client = {
      file = ../../secrets/ssh8022.age;
      mode = "444";
    };

    #borgbackup-fwminex = {
    #  file = ../../secrets/fwminex/borgbackup-password.age;
    #  owner = "motiejus";
    #};
  };

  boot = {
    kernelModules = [ "kvm-intel" ];
    kernelPackages = lib.mkForce linuxPackage;
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
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

  services.nsd = {
    enable = true;
    interfaces = [
      "0.0.0.0"
      "::"
    ];
    zones = {
      "jakstys.lt.".data = myData.jakstysLTZone;
    };
  };

  mj = {
    stateVersion = "24.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      devTools = true;
      root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
    };

    services = {
      ping_exporter.enable = true;

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      ssh8022.client = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-client.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
        acceptDNS = true;
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
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

      deployerbot = {
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

  environment.systemPackages = with pkgs; [
    (python3.withPackages (ps: [ ps.onvif-zeep ]))
    #linuxPackage.rr-zen_workaround # TODO(motiejus) broken on/since 2025-08
  ];

  powerManagement.cpuFreqGovernor = "performance";

  networking = {
    hostName = "vno1-gdrx";
    domain = "jakst.vpn";
    firewall = {
      rejectPackets = true;
      allowedUDPPorts = [
        53
      ];
    };
  };
}

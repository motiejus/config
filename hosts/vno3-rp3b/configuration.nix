# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running `nixos-help`).
{
  config,
  pkgs,
  myData,
  ...
}:
{
  imports = [ ../../modules/profiles/sdcard ];

  age.secrets = {
    motiejus-passwd-hash.file = ../../secrets/motiejus_passwd_hash.age;
    root-passwd-hash.file = ../../secrets/root_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;

    datapool-passphrase.file = ../../secrets/vno3-rp3b/datapool-passphrase.age;
  };

  boot = {
    initrd = {
      availableKernelModules = [ "usbhid" ];
      kernelModules = [
        "vc4"
        "bcm2835_dma"
      ];
    };
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    kernelModules = [ ];
    extraModulePackages = [ ];
    supportedFilesystems = [ "zfs" ];
    zfs.forceImportRoot = false;
  };

  powerManagement.cpuFreqGovernor = "ondemand";

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/44444444-4444-4444-8888-888888888888";
      fsType = "ext4";
    };
    "/data" = {
      device = "datapool/root";
      fsType = "zfs";
    };
    "/data/borg" = {
      device = "datapool/root/borg";
      fsType = "zfs";
    };
    "/data/shared" = {
      device = "datapool/root/shared";
      fsType = "zfs";
    };
  };

  swapDevices = [ ];

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
      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

      snapshot = {
        enable = true;
        mountpoints = [ "/data/shared" ];
      };
    };

    services = {
      printing.enable = true;
      tailscale.enable = true;
      node_exporter.enable = true;
      ping_exporter.enable = true;

      borgstor = {
        enable = true;
        dataDir = "/data/borg";
        sshKeys = with myData; [
          hosts."fwminex.servers.jakst".publicKey
          people_pubkeys.motiejus
        ];
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      jakstpub = {
        enable = true;
        dataDir = "/data/shared";
        requires = [ "data-shared.mount" ];
        uidgid = myData.uidgid.jakstpub;
        hostname = "hdd.jakstys.lt";
      };
    };
  };

  # shared printing
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  services.printing = {
    openFirewall = true;
    allowFrom = [ "all" ];
    browsing = true;
    defaultShared = true;
  };

  environment.etc = {
    "datapool-passphrase.txt".source = config.age.secrets.datapool-passphrase.path;
  };

  environment.systemPackages = with pkgs; [
    raspberrypi-eeprom
    libraspberrypi
    borgbackup
  ];

  networking = {
    hostId = "4bd17751";
    hostName = "vno3-rp3b";
    domain = "servers.jakst";
    dhcpcd.enable = true;
    firewall.rejectPackets = true;
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  security.rtkit.enable = true;
}

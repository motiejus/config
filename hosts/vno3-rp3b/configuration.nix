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
  };

  boot = {
    initrd = {
      availableKernelModules = [ "usbhid" ];
      kernelModules = [
        "vc4"
        "bcm2835_dma"
      ];
      luks.devices = {
        luksdata = {
          device = "/dev/disk/by-uuid/efa9b396-9ec0-40f7-a0d0-75edc0f6d5ad";
          allowDiscards = true;
          keyFileOffset = 9728;
          keyFileSize = 512;
          keyFile = "/dev/mmcblk1";
        };
      };

    };
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    kernelModules = [ ];
    extraModulePackages = [ ];
  };

  powerManagement.cpuFreqGovernor = "ondemand";

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/44444444-4444-4444-8888-888888888888";
      fsType = "ext4";
    };
    "/data" = {
      device = "/dev/mapper/luksdata";
      fsType = "btrfs";
      options = [ "compress=zstd" ];
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

      #snapshot = {
      #  enable = true;
      #  mountpoints = [ "/data/shared" ];
      #};
    };

    services = {
      printing.enable = true;
      tailscale.enable = true;
      node_exporter.enable = true;
      ping_exporter.enable = true;

      #borgstor = {
      #  enable = true;
      #  dataDir = "/data/borg";
      #  sshKeys = with myData; [
      #    hosts."fwminex.servers.jakst".publicKey
      #    people_pubkeys.motiejus
      #  ];
      #};

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

      #jakstpub = {
      #  enable = true;
      #  dataDir = "/data/shared";
      #  requires = [ "data-shared.mount" ];
      #  uidgid = myData.uidgid.jakstpub;
      #  hostname = "hdd.jakstys.lt";
      #};
    };
  };

  services = {
    chrony.extraConfig = ''
      makestep 1 -1
    '';

    # shared printing
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    printing = {
      openFirewall = true;
      allowFrom = [ "all" ];
      browsing = true;
      defaultShared = true;
    };
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

{config, ...}: let
  nvme = "/dev/disk/by-id/nvme-WDC_PC_SN730_SDBQNTY-256G-1001_19494D801165";
in {
  imports = [
    ../../modules
    ../../shared/platform/orangepi5plus.nix
  ];

  boot = {
    supportedFilesystems = ["bcachefs"];
    initrd = {
      kernelModules = ["usb_storage"];
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          keyFileOffset = 554;
          keyFileSize = 12;
          keyFile = "/dev/disk/by-id/usb-Generic_Flash_Disk_1EA30F29-0:0";
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
      fsType = "bcachefs";
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "ext4";
    };
  };

  mj = {
    stateVersion = "23.11";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      user.initialPassword = "live";
      root.initialPassword = "live";
    };

    services = {
      node_exporter.enable = true;
    };

    postfix = {
      enable = true;
      saslPasswdPath = config.age.secrets.sasl-passwd.path;
    };
  };

  services.pcscd.enable = true;

  networking = {
    hostName = "vno1-op5p";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [22];
  };
}

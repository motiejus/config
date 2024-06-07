{
  config,
  myData,
  ...
}: let
  #nvme = "/dev/disk/by-id/nvme-WDC_PC_SN730_SDBQNTY-256G-1001_19494D801165";
  nvme = "/dev/nvme0n1";
in {
  imports = [
    ../../modules

    ../../modules/profiles/btrfs

    ../../shared/platform/orangepi5plus.nix
  ];

  boot = {
    initrd = {
      kernelModules = ["usb_storage"];
      luks.devices = {
        luksroot = {
          #device = "${nvme}-part3";
          device = "${nvme}p3";
          allowDiscards = true;
          keyFileOffset = 9728;
          keyFileSize = 512;
          keyFile = "/dev/sda";
        };
      };
    };
  };

  swapDevices = [
    {
      device = "${nvme}p2";
      randomEncryption.enable = true;
    }
  ];

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luksroot";
      fsType = "btrfs";
      options = ["noatime" "compress=zstd"];
    };
    "/boot" = {
      device = "${nvme}1";
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
    };

    services = {
      tailscale.enable = true;
      node_exporter.enable = true;
      sshguard.enable = true;

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          inherit (myData.hosts."vno1-oh2.servers.jakst") publicKey;

          enable = true;
          sshAllowSubnets = [myData.subnets.tailscale.sshPattern];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };
    };
  };

  services.pcscd.enable = true;

  networking = {
    hostName = "vno1-op5p";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [22];
  };
}

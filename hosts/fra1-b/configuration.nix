{ myData, modulesPath, ... }:
let
  disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_50294864";
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot = {
    loader.systemd-boot.enable = true;
    initrd = {
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "virtio_scsi"
        "sr_mod"
      ];
    };
  };

  fileSystems = {
    "/boot" = {
      device = "${disk}-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
    "/" = {
      device = "${disk}-part3";
      fsType = "btrfs";
      options = [
        "compress=zstd"
        "noatime"
      ];
    };
  };

  swapDevices = [ { device = "${disk}-part2"; } ];

  mj = {
    stateVersion = "24.05";
    timeZone = "UTC";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.initialPassword = "live";
        user.initialPassword = "live";
        #root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        #user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

    };

    services = {
      node_exporter.enable = true;
      sshguard.enable = true;
      tailscale.enable = true;

      remote-builder.server = {
        enable = true;
        uidgid = myData.uidgid.remote-builder;
        sshAllowSubnet = myData.subnets.tailscale.sshPattern;
        publicKeys = map (h: myData.hosts.${h}.publicKey) [
          "vno1-oh2.servers.jakst"
          "fwminex.motiejus.jakst"
          "mtworx.motiejus.jakst"
        ];
      };

      #postfix = {
      #  enable = true;
      #  saslPasswdPath = config.age.secrets.sasl-passwd.path;
      #};

      deployerbot = {
        follower = {
          publicKeys = [
            myData.hosts."vno1-oh2.servers.jakst".publicKey
            myData.hosts."fwminex.motiejus.jakst".publicKey
          ];

          enable = true;
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

    };
  };

  services = {
    nsd = {
      enable = true;
      interfaces = [
        "0.0.0.0"
        "::"
      ];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
        "11sync.net.".data = myData.e11syncZone;
      };
    };
  };

  networking = {
    hostName = "fra1-b";
    domain = "servers.jakst";
    useDHCP = true;
    firewall = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [
        22
        53
      ];
    };
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}

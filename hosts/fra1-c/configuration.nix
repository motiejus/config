{
  config,
  myData,
  modulesPath,
  ...
}:
let
  disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_64370894";
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  age.secrets = {
    motiejus-passwd-hash.file = ../../secrets/motiejus_passwd_hash.age;
    root-passwd-hash.file = ../../secrets/root_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    ssh8022-server = {
      file = ../../secrets/ssh8022.age;
      owner = "spiped";
      path = "/var/lib/spiped/ssh8022.key";
    };
  };

  boot = {
    loader.grub = {
      enable = true;
      device = disk;
    };
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
    "/" = {
      device = "${disk}-part1";
      fsType = "btrfs";
      options = [
        "compress=zstd"
        "noatime"
      ];
    };
  };

  swapDevices = [ { device = "${disk}-part2"; } ];

  mj = {
    stateVersion = "25.05";
    timeZone = "UTC";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

    };

    services = {
      node_exporter.enable = true;
      ping_exporter.enable = true;
      tailscale.enable = true;

      ssh8022.server = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-server.path;
        openGlobalFirewall = false;
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];

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
      };
    };
  };

  powerManagement.cpuFreqGovernor = "performance";

  networking = {
    hostName = "fra1-c";
    domain = "jakst.vpn";
    useDHCP = true;
    #interfaces.enp1s0.ipv6.addresses = [
    #  {
    #    address = "2a01:4f8:c012:1ba::";
    #    prefixLength = 64;
    #  }
    #];
    defaultGateway6 = {
      address = "fe80::1";
      interface = "enp1s0";
    };
    firewall = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
}

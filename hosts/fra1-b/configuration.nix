{
  config,
  myData,
  modulesPath,
  ...
}:
let
  disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_50294864";
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  age.secrets = {
    motiejus-passwd-hash.file = ../../secrets/motiejus_passwd_hash.age;
    root-passwd-hash.file = ../../secrets/root_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    iodine-passwd.file = ../../secrets/iodine.age;
    ssh8022-server = {
      file = ../../secrets/ssh8022.age;
      owner = "spiped";
      path = "/var/lib/spiped/ssh8022.key";
    };

  };

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

      remote-builder.server = {
        enable = true;
        uidgid = myData.uidgid.remote-builder;
        sshAllowSubnet = myData.subnets.tailscale.sshPattern;
        publicKeys = map (h: myData.hosts.${h}.publicKey) [
          "vno1-gdrx.motiejus.jakst"
          "fwminex.servers.jakst"
          "mtworx.motiejus.jakst"
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

    };
  };

  services = {
    iodine.server = {
      enable = true;
      ip = "100.89.175.1/24";
      domain = "i.jakstys.lt";
      passwordFile = config.age.secrets.iodine-passwd.path;
      #extraConfig = "-c -b ${toString myData.ports.nsd-unwrapped}";
      extraConfig = "-c";
    };

    nsd = {
      enable = true;
      port = myData.ports.nsd-unwrapped;
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
      allowedTCPPorts = [ 53 ];
    };
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}

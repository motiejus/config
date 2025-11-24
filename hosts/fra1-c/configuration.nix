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
    motiejus-server-passwd-hash.file = ../../secrets/motiejus_server_passwd_hash.age;
    root-server-passwd-hash.file = ../../secrets/root_server_passwd_hash.age;
    borgbackup-password.file = ../../secrets/fwminex/borgbackup-password.age;
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
        root.hashedPasswordFile = config.age.secrets.root-server-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-server-passwd-hash.path;
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

      headscale = {
        enable = true;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];

          enable = true;
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/var/lib";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/var/lib";
            label = "5minutely";
            keep = 12;
            refreshInterval = "*:0/5";
          }
        ];
      };

      btrfsborg =
        let
          this = "${config.networking.hostName}.${config.networking.domain}";
          rsync-net = "zh2769@zh2769.rsync.net";
          vno3-nk = "borgstor@vno3-nk.jakst.vpn";
        in
        {
          enable = true;
          passwordPath = config.age.secrets.borgbackup-password.path;
          sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
          dirs =
            builtins.concatMap
              (
                host:
                let
                  prefix = "${host}:${this}";
                in
                [
                  {
                    subvolume = "/var/lib";
                    repo = "${prefix}-var_lib";
                    paths = [ "headscale" ];
                    backup_at = "*-*-* 01:00:01 UTC";
                  }
                ]
              )
              [
                rsync-net
                vno3-nk
              ];
        };

    };
  };

  services = {
    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      globalConfig = ''
        servers {
          metrics {
            per_host
          }
        }
      '';
      virtualHosts = {
        "vpn.jakstys.lt".extraConfig = ''reverse_proxy 127.0.0.1:${toString myData.ports.headscale}'';
      };
    };

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
    hostId = "98256a58";
    useDHCP = true;
    interfaces.enp1s0.ipv6.addresses = [
      {
        address = myData.hosts."fra1-c.jakst.vpn".publicIP6;
        prefixLength = 64;
      }
    ];
    defaultGateway6 = {
      address = "fe80::1";
      interface = "enp1s0";
    };
    firewall = {
      allowedUDPPorts = [
        53
        443
      ];
      allowedTCPPorts = [
        53
        80
        443
      ];
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
}

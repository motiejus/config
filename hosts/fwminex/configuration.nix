{
  config,
  pkgs,
  myData,
  ...
}: {
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = ["nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A"];
      immutable = false;
      forceNoDev2305 = true;
      availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usbhid" ];
      removableEfi = true;
      partitionScheme = {
        efiBoot = "-part1";
        bootPool = "-part2";
        rootPool = "-part4";
      };
    };
  };

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  swapDevices = [{device = "/dev/zvol/rpool/swap";}];

  boot.loader.grub.extraEntries = ''
    menuentry "Debian via bpool label" {
      search --set=bpool --label bpool
      configfile "$(bpool)/@/BOOT/debian@/grub/grub.cfg"
    }
    menuentry "Debian 3915eee7610a7d61" {
      search --set=root 3915eee7610a7d61
      configfile "/BOOT/debian@/grub/grub.cfg"
    }
    menuentry "Debian 4113456512205749601" {
      search --set=root 4113456512205749601
      configfile "/BOOT/debian@/grub/grub.cfg"
    }
  '';

  fileSystems."/var/lib/docker" = {
    device = "rpool/nixos/var/docker";
    fsType = "zfs";
  };

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";

    base = {
      zfs.enable = true;
      users = {
        devEnvironment = true;
        passwd = {
          root.initialPassword = "live";
          motiejus.initialPassword = "live";
          motiejus.extraGroups = ["networkmanager"];
          #root.passwordFile = config.age.secrets.root-passwd-hash.path;
          #motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
        };
      };

      snapshot = {
        enable = true;
        mountpoints = ["/home" "/var/lib" "/var/log"];
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

    };

    services = {
      node_exporter.enable = true;
      sshguard.false = true;

      deployerbot = {
        follower = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          publicKey = myData.hosts."vno1-oh2.servers.jakst".publicKey;
        };
      };

      #postfix = {
      #  enable = true;
      #  saslPasswdPath = config.age.secrets.sasl-passwd.path;
      #};

      syncthing = {
        enable = false;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };

    };
  };

  services = {
    tailscale.enable = true;

    xserver = {
      enable = true;
      desktopManager.gnome.enable = true;
      displayManager.gdm.enable = true;
    };
  };

  networking = {
    hostId = "3a54afcd";
    hostName = "fwminex";
    domain = "motiejus.jakst";
    networkmanager.enable = true;
  };
}

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
      availableKernelModules = ["usb_storage" "sd_mod" "iwlwifi" "xhci_pci" "thunderbolt" "nvme" "usbhid"];
      removableEfi = true;
      partitionScheme = {
        efiBoot = "-part1";
        bootPool = "-part2";
        rootPool = "-part4";
      };
    };
  };

  powerManagement.cpuFreqGovernor = "powersave";
  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  #swapDevices = [];

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

  systemd.services.zfs-mount.enable = false;

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
      sshguard.enable = false;
      tailscale = {
        enable = true;
        silenceLogs = true;
      };

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

  environment.systemPackages = with pkgs; [
    texlive.combined.scheme-medium
  ];

  networking = {
    hostId = "3a54afcd";
    hostName = "fwminex";
    domain = "motiejus.jakst";
  };
}

{
  config,
  myData,
  ...
}: let
  randr = import ./randr.nix;
in {
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = ["nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A"];
      immutable = false;
      forceNoDev2305 = true;
      availableKernelModules = ["usb_storage" "sd_mod" "xhci_pci" "thunderbolt" "nvme" "usbhid"];
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

  systemd.services.zfs-mount.enable = false;

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";

    base = {
      zfs.enable = true;
      users = {
        devEnvironment = true;
        passwd = {
          root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
          motiejus.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
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
      sshguard.enable = false;
      tailscale = {
        enable = true;
        verboseLogs = true;
      };

      node_exporter = {
        enable = true;
        extraSubnets = [myData.subnets.vno1.cidr];
      };

      deployerbot = {
        follower = {
          inherit (myData.hosts."vno1-oh2.servers.jakst") publicKey;

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [tailscale.sshPattern];
        };
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };
    };
  };

  services.autorandr = {
    enable = true;
    profiles = {
      default = {
        fingerprint = {inherit (randr) eDP-1;};
        config = {
          DP-1.enable = false;
          DP-2.enable = false;
          DP-3.enable = false;
          DP-4.enable = false;
          eDP-1 = {
            enable = true;
            primary = true;
            mode = "1920x1200";
            crtc = 0;
            position = "0x0";
            rate = "59.88";
          };
        };
      };

      dualhome = {
        fingerprint = {inherit (randr) eDP-1 DP-3 DP-4;};
        config = {
          eDP-1.enable = false;
          DP-1.enable = false;
          DP-2.enable = false;
          DP-3 = {
            enable = true;
            mode = "2560x1440";
            position = "0x0";
            crtc = 1;
            rate = "59.95";
          };
          DP-4 = {
            enable = true;
            mode = "2560x1440";
            position = "2560x0";
            primary = true;
            crtc = 0;
            rate = "59.95";
          };
        };
      };
    };
  };

  networking = {
    hostId = "3a54afcd";
    hostName = "fwminex";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };
}

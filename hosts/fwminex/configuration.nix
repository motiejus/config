{
  pkgs,
  config,
  myData,
  ...
}: let
  randr = import ./randr.nix;
in {
  boot = {
    initrd.availableKernelModules = ["usb_storage" "sd_mod" "xhci_pci" "thunderbolt" "nvme" "usbhid"];
    kernelPackages = pkgs.zfs.latestCompatibleLinuxPackages;
    loader.systemd-boot.enable = true;
    supportedFilesystems = ["zfs"];
    zfs = {
      forceImportRoot = false;
      devNodes = "/dev/disk/by-id/";
    };
  };

  fileSystems = {
    "/" = {
      device = "rpool/nixos/root";
      fsType = "zfs";
    };
    "/boot" = {
      device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A_1-part2";
      fsType = "vfat";
    };
    "/home" = {
      device = "rpool/nixos/home";
      fsType = "zfs";
    };
    "/nix" = {
      device = "rpool/nixos/nix";
      fsType = "zfs";
    };
    "/var/lib" = {
      device = "rpool/nixos/var/lib";
      fsType = "zfs";
    };
    "/var/log" = {
      device = "rpool/nixos/var/log";
      fsType = "zfs";
    };
  };

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  systemd.services.zfs-mount.enable = false;

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base = {
      zfs.enable = true;
      users = {
        enable = true;
        devTools = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
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

      remote-builder.client = let
        host = myData.hosts."fra1-a.servers.jakst";
      in {
        enable = true;
        inherit (host) system supportedFeatures;
        hostName = host.jakstIP;
        sshKey = "/etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  services = {
    autorandr = {
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

        home1 = {
          fingerprint = {inherit (randr) eDP-1 DP-4;};
          config = {
            eDP-1.enable = false;
            DP-1.enable = false;
            DP-2.enable = false;
            DP-4 = {
              enable = true;
              mode = "2560x1440";
              position = "0x0";
              primary = true;
              crtc = 0;
              rate = "59.95";
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
  };

  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = ["motiejus"];

  environment.systemPackages = with pkgs; [
    tesseract
  ];

  networking = {
    hostId = "3a54afcd";
    hostName = "fwminex";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };
}

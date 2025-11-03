{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-WDC_WDS250G2B0C-00PXH0_2043E7802918";
in
{
  imports = [
    ../../modules
    ../../modules/profiles/xfce4
    ../../modules/profiles/btrfs
  ];

  services.xserver.desktopManager.xfce.enableScreensaver = false;

  age.secrets = {
    motiejus-passwd-hash.file = ../../secrets/motiejus_passwd_hash.age;
    root-passwd-hash.file = ../../secrets/root_passwd_hash.age;
    syncthing-key.file = ../../secrets/sqq1-desk2/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/sqq1-desk2/syncthing/cert.pem.age;
  };

  boot = {
    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "ahci"
        "usbhid"
        "tpm_tis"
      ];
    };
  };

  swapDevices = [ { device = "${nvme}-part2"; } ];

  fileSystems = {
    "/" = {
      device = "${nvme}-part3";
      fsType = "btrfs";
      options = [ "compress=zstd" ];
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "vfat";
    };
  };

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  users.users.irena = {
    isNormalUser = true;
    extraGroups = [
      "networkmanager"
      "users"
    ];
    password = "";
  };

  services.displayManager.autoLogin.user = lib.mkForce "irena";

  home-manager.users.irena = {
    home = {
      stateVersion = "25.05";
      language = {
        base = "lt_LT.UTF-8";
      };
      sessionVariables = {
        LANGUAGE = "lt:ru:en";
      };
    };

    programs.firefox = {
      enable = true;
      languagePacks = [
        "lt"
        "ru"
      ];
      profiles.default = {
        isDefault = true;
        extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
          ublock-origin
          consent-o-matic
          multi-account-containers
        ];
        settings = {
          "intl.locale.requested" = "lt,ru,en-US";
        };
      };
    };
  };

  mj = {
    stateVersion = "25.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };
    };

    services = {
      node_exporter.enable = true;

      syncthing = {
        enable = true;
        user = "irena";
        group = "users";
        dataDir = "/home/irena";
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
        acceptDNS = true;
      };

      deployerbot.follower = {
        enable = true;
        uidgid = myData.uidgid.updaterbot-deployee;
        publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];
        sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
      };
    };
  };

  environment = {
    systemPackages = with pkgs; [
      kdePackages.kpat
      kdePackages.kmahjongg
      kdePackages.kmines
      kdePackages.ksudoku
      kdePackages.kblocks
      kdePackages.kbounce
      kdePackages.kbreakout
      kdePackages.kgoldrunner
      kdePackages.klickety
      kdePackages.klines
      kdePackages.kollision
      kdePackages.kreversi
      kdePackages.kshisen
      kdePackages.ksquares
      kdePackages.kfourinline
      kdePackages.kiriki

      extremetuxracer
      superTux
      superTuxKart
      frozen-bubble
      neverball
      pingus
      supermariowar
    ];
  };

  networking = {
    hostId = "c14cbb01";
    hostName = "sqq1-desk2";
    domain = "jakst.vpn";
    firewall.rejectPackets = true;
  };
}

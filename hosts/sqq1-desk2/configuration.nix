{
  config,
  lib,
  pkgs,
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
      tailscale = {
        enable = true;
        verboseLogs = true;
        acceptDNS = true;
      };
    };
  };

  environment = {
    systemPackages = with pkgs; [ ];
  };

  networking = {
    hostId = "c14cbb01";
    hostName = "sqq-desk2";
    domain = "jakst.vpn";
    firewall.rejectPackets = true;
  };
}

{
  myData,
  pkgs,
  config,
  ...
}: let
  nvme = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A_1";
in {
  imports = [
    ../../modules
    ../../modules/profiles/btrfs
  ];

  boot = {
    kernelModules = ["kvm-intel"];
    loader.systemd-boot.enable = true;
    initrd = {
      availableKernelModules = ["xhci_pci" "thunderbolt" "nvme" "usbhid" "tpm_tis"];
      systemd = {
        enableTpm2 = true;
        emergencyAccess = true;
      };
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          crypttabExtraOpts = ["tpm2-device=auto"];
        };
      };
    };
  };

  security.tpm2.enable = true;

  swapDevices = [
    {
      device = "${nvme}-part2";
      randomEncryption.enable = true;
    }
  ];

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luksroot";
      fsType = "btrfs";
      options = ["compress=zstd"];
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "vfat";
    };
  };

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.services.zfs-mount.enable = false;

  services = {
    pcscd.enable = true;
    acpid.enable = true;
    fwupd.enable = true;
    logind = {
      lidSwitch = "ignore";
      powerKey = "suspend";
      powerKeyLongPress = "poweroff";
    };
  };

  mj = {
    stateVersion = "24.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
    };

    services = {
      sshguard.enable = false;
      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      #remote-builder.client = let
      #  host = myData.hosts."fra1-a.servers.jakst";
      #in {
      #  enable = true;
      #  inherit (host) system supportedFeatures;
      #  hostName = host.jakstIP;
      #  sshKey = "/etc/ssh/ssh_host_ed25519_key";
      #};

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
    };
  };

  environment = {
    systemPackages = with pkgs; [
      age-plugin-yubikey
    ];
  };

  networking = {
    hostId = "a6b19da0";
    hostName = "fwminex";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };
}

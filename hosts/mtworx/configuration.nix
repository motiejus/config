{
  pkgs,
  #config,
  myData,
  ...
}: let
  nvme = "nvme-WD_PC_SN810_SDCQNRY-1T00-1201_23234W800017";
in {
  imports = [
    ../../modules
    ../../modules/profiles/desktop
  ];

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = ["kvm-intel"];
    supportedFilesystems = ["bcachefs"];
    loader.systemd-boot.enable = true;
    initrd = {
      availableKernelModules = ["xhci_pci" "thunderbolt" "nvme" "usbhid"];
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
        };
      };
    };
  };

  swapDevices = [
    {
      device = "${nvme}-part2";
      randomEncryption.enable = true;
    }
  ];

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luksroot";
      fsType = "bcachefs";
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "vfat";
    };
  };

  powerManagement.cpuFreqGovernor = "powersave";

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  systemd.services.zfs-mount.enable = false;

  mj = {
    stateVersion = "23.11";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      root.initialPassword = "live";
      user.initialPassword = "live";
      #root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
      #user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
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

      #postfix = {
      #  enable = true;
      #  saslPasswdPath = config.age.secrets.sasl-passwd.path;
      #};

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };

      #remote-builder.client = let
      #  host = myData.hosts."fra1-a.servers.jakst";
      #in {
      #  enable = true;
      #  inherit (host) system supportedFeatures;
      #  hostName = host.jakstIP;
      #  sshKey = "/etc/ssh/ssh_host_ed25519_key";
      #};
    };
  };

  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = ["motiejus"];

  networking = {
    hostId = "b14a02aa";
    hostName = "mtworx";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };

  services.tlp = {
    enable = true;
    settings = {
      CPU_BOOST_ON_BAT = 0;
      CPU_HWP_DYN_BOOST_ON_BAT = 0;
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      PLATFORM_PROFILE_ON_BAT = "low-power";
      START_CHARGE_THRESH_BAT1 = 80;
      STOP_CHARGE_THRESH_BAT1 = 87;
      RUNTIME_PM_ON_BAT = "auto";
    };
  };
}

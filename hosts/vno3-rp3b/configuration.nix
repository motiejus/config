# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running `nixos-help`).
{
  config,
  pkgs,
  myData,
  ...
}: {
  # previously:
  # imports = [(modulesPath + "/installer/scan/not-detected.nix")];
  # as of 23.05 that is:

  boot.initrd.availableKernelModules = ["usbhid"];
  boot.initrd.kernelModules = ["vc4" "bcm2835_dma" "i2c_bcm2835"];
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.kernelModules = [];
  boot.extraModulePackages = [];
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = false;

  powerManagement.cpuFreqGovernor = "ondemand";

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/44444444-4444-4444-8888-888888888888";
    fsType = "ext4";
  };

  fileSystems."/data" = {
    device = "datapool/root";
    fsType = "zfs";
  };
  fileSystems."/data/borg" = {
    device = "datapool/root/borg";
    fsType = "zfs";
  };
  fileSystems."/data/shared" = {
    device = "datapool/root/shared";
    fsType = "zfs";
  };

  swapDevices = [];

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";
    base = {
      zfs.enable = true;
      users.passwd = {
        root.passwordFile = config.age.secrets.root-passwd-hash.path;
        motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
      };
      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

      snapshot = {
        enable = true;
        mountpoints = ["/data/shared"];
      };
    };

    services = {
      tailscale.enable = true;
      node_exporter.enable = true;
      sshguard.enable = true;

      certget = {
        enable = true;
        uidgid = myData.uidgid.certget;
        sshKeys = [myData.hosts."vno1-oh2.servers.jakst".publicKey];
      };

      borgstor = {
        enable = true;
        dataDir = "/data/borg";
        sshKeys = [
          myData.hosts."vno1-oh2.servers.jakst".publicKey
          myData.people_pubkeys.motiejus
        ];
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          inherit (myData.hosts."vno1-oh2.servers.jakst") publicKey;

          enable = true;
          sshAllowSubnets = [myData.subnets.tailscale.sshPattern];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      jakstpub = {
        enable = true;
        dataDir = "/data/shared";
        requires = ["data-shared.mount"];
        uidgid = myData.uidgid.jakstpub;
        hostname = "hdd.jakstys.lt";
      };
    };
  };

  #services.journald.extraConfig = "Storage=volatile";

  environment.etc = {
    "datapool-passphrase.txt".source = config.age.secrets.datapool-passphrase.path;
  };

  environment.systemPackages = with pkgs; [
    libraspberrypi
    borgbackup
  ];

  networking = {
    hostId = "4bd17751";
    hostName = "vno3-rp3b";
    domain = "servers.jakst";
    dhcpcd.enable = true;
    firewall.rejectPackets = true;
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  security.rtkit.enable = true;
}

{
  lib,
  config,
  pkgs,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-WD_PC_SN810_SDCQNRY-1T00-1201_23234W800017";
in
{
  imports = [
    ../../shared/work
    ../../modules
    ../../modules/profiles/desktop
    ../../modules/profiles/autorandr
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-work-passwd-hash.file = ../../secrets/motiejus_work_passwd_hash.age;
    root-work-passwd-hash.file = ../../secrets/root_work_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;

    syncthing-key.file = ../../secrets/mtworx/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/mtworx/syncthing/cert.pem.age;

    ssh8022-client = {
      file = ../../secrets/ssh8022.age;
      mode = "444";
    };
  };

  boot = {
    kernelModules = [ "kvm-intel" ];
    loader.systemd-boot.enable = true;

    # 6.10+ to fix audio. Thanks https://github.com/ilian/cfg/blob/4588b90e674827304cd8e0b9d1aecd75416d1cde/hosts/carbon/configuration.nix#L19
    kernelPackages = pkgs.linuxPackages_6_10;

    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      systemd = {
        enableTpm2 = true;
        emergencyAccess = true;
      };
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          crypttabExtraOpts = [ "tpm2-device=auto" ];
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

  mj = {
    stateVersion = "23.11";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base.users = {
      enable = true;
      devTools = true;
      root.hashedPasswordFile = config.age.secrets.root-work-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-work-passwd-hash.path;
    };

    services = {
      ssh8022.client = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-client.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
      };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/home";
            label = "5minutely";
            keep = 12;
            refreshInterval = "*:0/5";
          }
          {
            subvolume = "/home";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/home";
            label = "daily";
            keep = 7;
            refreshInterval = "daily UTC";
          }
        ];
      };

      wifibackup = {
        enable = true;
        toPath = "/home/${config.mj.username}/M-Active/.wifi";
        toUser = config.mj.username;
      };

      remote-builder.client =
        let
          host = myData.hosts."fra1-b.servers.jakst";
        in
        {
          enable = true;
          inherit (host) system supportedFeatures;
          hostName = host.jakstIP;
          sshKey = "/etc/ssh/ssh_host_ed25519_key";
          maxJobs = 2;
        };

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [ tailscale.sshPattern ];
        };
      };

      postfix = {
        enable = false;
        #saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
      };

    };
  };

  users = {
    users.mount-test = {
      name = "mount-test";
      group = "mount-test";
      isSystemUser = true;
    };
    groups.mount-test = { };
  };

  systemd.tmpfiles.rules = [ "d /data 0755 root root -" ];

  systemd.services.mount-test = {
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      RuntimeDirectory = "mount-test";
      TemporaryFileSystem = "/data";
      BindPaths = [ "/home/motiejus/x:/var/run/mount-test/bind-paths/x" ];
      PrivateDevices = false;

      Type = "simple";
      Restart = "on-failure";
      RestartSec = 10;

      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateMounts = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      CapabilityBoundingSet = lib.mkForce "CAP_SYS_ADMIN | CAP_SETUID | CAP_SETGID";

      User = "mount-test";
      Group = "mount-test";
      ExecStart =
        "!"
        + (lib.getExe (
          pkgs.writeShellApplication {
            name = "mount-test";
            runtimeInputs = with pkgs; [
              bindfs
              util-linux
            ];
            text = ''
              set -x
              mkdir -p /data/x
              bindfs -d -u motiejus -g users /var/run/mount-test/bind-paths/x /data/x &
              sleep 1
              #exec setpriv \
              #  --ruid mount-test \
              #  --inh-caps -sys_admin,-setuid,-setgid \
              touch /data/x/foo
            '';
          }
        ));
    };
  };

  users.extraGroups.vboxusers.members = [ "motiejus" ];

  environment.systemPackages = with pkgs; [ dnsmasq ];

  security.tpm2.enable = true;

  networking = {
    hostId = "b14a02aa";
    hostName = "mtworx";
    domain = "motiejus.jakst";
    firewall.rejectPackets = true;
  };
}

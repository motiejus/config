{
  pkgs,
  config,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NS0TA01331A_1";
in
{
  imports = [
    ../../modules
    ../../modules/profiles/btrfs
  ];

  boot = {
    kernelModules = [ "kvm-intel" ];
    loader.systemd-boot.enable = true;
    initrd = {
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];
      systemd.enableTpm2 = true;
      luks.devices = {
        luksroot = {
          device = "${nvme}-part3";
          allowDiscards = true;
          #crypttabExtraOpts = ["tpm2-device=auto"];
          keyFileOffset = 9728;
          keyFileSize = 512;
          keyFile = "/dev/sda";
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
      options = [ "compress=zstd" ];
    };
    "/boot" = {
      device = "${nvme}-part1";
      fsType = "vfat";
    };
  };

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.tmpfiles.rules = [ "d /var/www 0755 motiejus users -" ];

  services = {
    pcscd.enable = true;
    acpid.enable = true;
    fwupd.enable = true;
    logind = {
      lidSwitch = "ignore";
      powerKey = "suspend";
      powerKeyLongPress = "poweroff";
    };

    caddy = {
      enable = true;
      globalConfig = ''
        auto_https off
      '';
    };
  };

  mj = {
    stateVersion = "24.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-server-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-server-passwd-hash.path;
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      sshguard.enable = false;
      gitea.enable = true;

      tailscale = {
        enable = true;
        verboseLogs = false;
      };

      headscale = {
        enable = true;
        clientOidcPath = config.age.secrets.headscale-client-oidc.path;
        subnetCIDR = myData.subnets.tailscale.cidr;
      };

      btrfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        dirs =
          builtins.concatMap
            (
              host:
              let
                prefix = "${host}:${config.networking.hostName}.${config.networking.domain}";
              in
              [
                {
                  subvolume = "/var/lib";
                  repo = "${prefix}-var_lib";
                  paths = [
                    "headscale"
                    "gitea"
                  ];
                  patterns = [ "- gitea/data/repo-archive/" ];
                  backup_at = "*-*-* 01:00:01 UTC";
                }
                {
                  subvolume = "/home";
                  repo = "${prefix}-home-motiejus-annex2";
                  paths = [ "motiejus/annex2" ];
                  backup_at = "*-*-* 02:30:01 UTC";
                }
              ]
            )
            [
              "zh2769@zh2769.rsync.net"
              "borgstor@${myData.hosts."vno3-rp3b.servers.jakst".jakstIP}"
            ];
      };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            subvolume = "/home";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/home";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
          }
          {
            subvolume = "/var/lib";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/var/lib";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
          }
        ];
      };

      syncthing = {
        enable = true;
        dataDir = "/home/motiejus/";
        user = "motiejus";
        group = "users";
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
        };

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        main = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployer;
          repo = "git@git.jakstys.lt:motiejus/config";
          deployDerivations = [
            ".#fwminex"
            ".#vno1-oh2"
            ".#fra1-b"
            ".#vno3-rp3b"
          ];
          deployIfPresent = [
            {
              derivationTarget = ".#mtworx";
              pingTarget = myData.hosts."mtworx.motiejus.jakst".jakstIP;
            }
          ];
        };

        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          sshAllowSubnets = with myData.subnets; [ tailscale.sshPattern ];
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
      acpi
      age-plugin-yubikey
    ];
  };

  networking = {
    hostId = "a6b19da0";
    hostName = "fwminex";
    domain = "servers.jakst";
    firewall = {
      rejectPackets = true;
      allowedUDPPorts = [
        53
        80
        443
      ];
      allowedTCPPorts = [
        53
        80
        443
        config.services.syncthing.relay.port
        config.services.syncthing.relay.statusPort
      ];
    };
  };
}

{
  config,
  myData,
  pkgs,
  ...
}:
let
  disk = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_2TB_S754NX0W731206W";
in
{
  imports = [
    ../../modules
    ../../modules/profiles/physical
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-server-passwd-hash.file = ../../secrets/motiejus_server_passwd_hash.age;
    root-server-passwd-hash.file = ../../secrets/root_server_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;
    borgbackup-password.file = ../../secrets/${config.networking.hostName}/borgbackup-password.age;
    timelapse.file = ../../secrets/timelapse.age;
    # owned by the capture user, so every timelapse tool runs as that user and
    # nothing in its tree ends up owned by root
    timelapse-merger-key = {
      file = ../../secrets/vno3-nk/timelapse-merger-key.age;
      owner = "timelapse-r11";
    };
    syncthing-key.file = ../../secrets/vno3-nk/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/vno3-nk/syncthing/cert.pem.age;
    ssh8022-server = {
      file = ../../secrets/ssh8022.age;
      owner = "spiped";
      path = "/var/lib/spiped/ssh8022.key";
    };
  };

  boot = {
    loader.systemd-boot.enable = true;
    initrd = {
      systemd.enable = true;
      kernelModules = [ "usb_storage" ];
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "ahci"
        "usbhid"
        "tpm_tis"
      ];
    };
  };

  mj.profiles.btrfs.disk = disk;

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  mj = {
    stateVersion = "24.11";
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
      ping_exporter.enable = true;

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno3.cidr ];
      };

      timelapse-r11 = {
        enable = true;
        onCalendar = "*-*-* *:*:30"; # 30'th second every minute
        secretsEnv = config.age.secrets.timelapse.path;
      };

      ssh8022.server = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-server.path;
      };

      borgstor = {
        enable = true;
        dataDir = "/data/borg";
        sshKeys = with myData; [
          hosts."fwminex.jakst.vpn".publicKey
          hosts."fra1-c.jakst.vpn".publicKey
          people_pubkeys.motiejus
        ];
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
      };

      btrfsborg =
        let
          this = "${config.networking.hostName}.${config.networking.domain}";
          rsync-net = "zh2769@zh2769.rsync.net";
          fwminex = "borgstor@fwminex.jakst.vpn";
        in
        {
          enable = true;
          passwordPath = config.age.secrets.borgbackup-password.path;
          sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
          dirs =
            builtins.concatMap
              (
                host:
                let
                  prefix = "${host}:${this}";
                in
                [
                  {
                    subvolume = "/data";
                    repo = "${prefix}-data";
                    paths = [ "vno3-shared" ];
                    backup_at = "*-*-* 01:00:01 UTC";
                  }
                  {
                    # The finished timelapse videos are the only copy once
                    # timelapse-reap deletes the stills, and nothing else on
                    # this host backs up /var/lib. Snapshotted through / rather
                    # than /var/lib, which is not a subvolume here.
                    subvolume = "/";
                    repo = "${prefix}-timelapse";
                    paths = [ "var/lib/timelapse-r11/videos" ];
                    backup_at = "*-*-* 03:20:00 UTC";
                    compression = "none";
                  }
                ]
              )
              [
                rsync-net
                fwminex
              ];
        };

      btrfssnapshot = {
        enable = true;
        subvolumes = [
          {
            # next time: don't forget a subvolume /var/lib
            subvolume = "/";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/";
            label = "5minutely";
            keep = 12;
            refreshInterval = "*:0/5";
          }
          {
            subvolume = "/data";
            label = "hourly";
            keep = 24;
            refreshInterval = "*:00:00";
          }
          {
            subvolume = "/data";
            label = "nightly";
            keep = 7;
            refreshInterval = "daily UTC";
          }
        ];
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          enable = true;
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      jakstpub = {
        enable = true;
        dataDir = "/data/vno3-shared";
        uidgid = myData.uidgid.jakstpub;
        hostname = "hdd.jakstys.lt";
      };

      syncthing = {
        enable = true;
        dataDir = "/var/lib/jakstpub/";
        user = "jakstpub";
        group = "jakstpub";
      };

    };
  };

  environment = {
    enableDebugInfo = true;
    systemPackages = with pkgs; [
      yt-dlp
      intel-gpu-tools

      # run by hand for now; the timer that drives them comes later
      timelapse-merger
      timelapse-videomaker
      timelapse-daily
      timelapse-reap
    ];
  };

  networking = {
    hostId = "ab4af0bb";
    hostName = "vno3-nk";
    domain = "jakst.vpn";
    firewall = {
      rejectPackets = true;
      allowedUDPPorts = [
        80
        443
      ];
      allowedTCPPorts = [
        80
        443
      ];
    };
  };
}

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
        # This host only captures. fwminex builds the videos, pulling whatever
        # its own 5-minute tree missed from here, so it needs read access.
        readerKeys = [ myData.bot_pubkeys.timelapse_merger_fwminex ];
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
          # Clear of this host's own backups and of the ones fwminex pushes here.
          checkAt = "Sun *-*-* 07:00:00 UTC";
          dirs =
            builtins.concatMap
              (
                host:
                let
                  prefix = "${host}:${this}";
                in
                [
                  {
                    # 41 GB of photographs and video in 1083 files, written
                    # once and never rewritten, so history here is nearly free:
                    # on the comparable annex2 repo 593 archives cost 2.8 GB
                    # between them. The module default would keep four weeks,
                    # which is how long you have to notice a deletion before
                    # both copies of it are gone.
                    subvolume = "/data";
                    repo = "${prefix}-data";
                    paths = [ "vno3-shared" ];
                    prune.keep = {
                      within = "10y";
                      last = 3;
                    };
                    backup_at = "*-*-* 01:00:01 UTC";
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
      ffmpeg-headless # ffprobe/ffmpeg by hand; the timelapse tools carry their own
      intel-gpu-tools

      # for filling this host's own gaps by hand; the archive itself is built on
      # fwminex, which is where the other three tools live
      timelapse-merger
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

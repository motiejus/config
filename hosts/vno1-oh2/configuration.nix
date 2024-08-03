{
  config,
  pkgs,
  myData,
  ...
}:
{
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = [ "nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NX0TA00913P" ];
      immutable = false;
      availableKernelModules = [
        "ahci"
        "xhci_pci"
        "nvme"
        "usbhid"
        "sdhci_pci"
        "r8169" # builtin non working
        "r8152" # startech usb-ethernet adapter
      ];
      removableEfi = true;
      kernelParams = [
        "ip=192.168.189.1::192.168.189.4:255.255.255.0:vno1-oh2.jakstys.lt:enp0s21f0u2:off"
      ];
    };
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";
    username = "motiejus";

    base = {
      zfs.enable = true;
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      snapshot = {
        enable = true;
        mountpoints = [
          "/home"
          "/var/lib"
          "/var/log"
        ];
      };

      zfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        sshKeyPath = "/etc/ssh/ssh_host_ed25519_key";
        dirs = [
          # TODO merge
          {
            mountpoint = "/var/lib";
            repo = "zh2769@zh2769.rsync.net:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "tailscale"
              "private/soju"
            ];
            backup_at = "*-*-* 01:00:00 UTC";
            prune.keep = {
              within = "1d";
              daily = 1;
              weekly = 0;
              monthly = 0;
            };
          }
          {
            mountpoint = "/var/lib";
            repo = "borgstor@${
              myData.hosts."vno3-rp3b.servers.jakst".jakstIP
            }:${config.networking.hostName}.${config.networking.domain}-var_lib";
            paths = [
              "tailscale"
              "private/soju"
            ];
            backup_at = "*-*-* 01:00:00 UTC";
          }

        ];
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      friendlyport.ports = [
        {
          subnets = [ myData.subnets.tailscale.cidr ];
          tcp = with myData.ports; [
            80
            443
            soju
            soju-ws
          ];
        }
      ];

      tailscale.enable = true;
      node_exporter.enable = true;
      sshguard.enable = true;

      nsd-acme =
        let
          accountKey = config.age.secrets.letsencrypt-account-key.path;
        in
        {
          enable = true;
          zones = {
            "irc.jakstys.lt".accountKey = accountKey;
            "hdd.jakstys.lt".accountKey = accountKey;
            "grafana.jakstys.lt".accountKey = accountKey;
            "bitwarden.jakstys.lt".accountKey = accountKey;
          };
        };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.servers.jakst".publicKey ];

          enable = true;
          sshAllowSubnets = [ myData.subnets.tailscale.sshPattern ];
          uidgid = myData.uidgid.updaterbot-deployee;
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

      matrix-synapse = {
        enable = true;
        signingKeyPath = config.age.secrets.synapse-jakstys-signing-key.path;
        registrationSharedSecretPath = config.age.secrets.synapse-registration-shared-secret.path;
        macaroonSecretKeyPath = config.age.secrets.synapse-macaroon-secret-key.path;
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
    };
  };

  services = {

    nsd = {
      enable = true;
      interfaces = [
        "0.0.0.0"
        "::"
      ];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
        "11sync.net.".data = myData.e11syncZone;
      };
    };

    soju = {
      enable = true;
      listen = [
        #"unix+admin://"
        ":${toString myData.ports.soju}"
        "wss://:${toString myData.ports.soju-ws}"
      ];
      tlsCertificate = "/run/soju/cert.pem";
      tlsCertificateKey = "/run/soju/key.pem";
      hostName = "irc.jakstys.lt";
      httpOrigins = [ "*" ];
      extraConfig = ''
        message-store fs /var/lib/soju
      '';
    };

    #syncthing.relay = {
    #  enable = true;
    #  providedBy = "11sync.net";
    #};
  };

  systemd.services = {
    soju =
      let
        acme = config.mj.services.nsd-acme.zones."irc.jakstys.lt";
      in
      {
        serviceConfig = {
          RuntimeDirectory = "soju";
          LoadCredential = [
            "irc.jakstys.lt-cert.pem:${acme.certFile}"
            "irc.jakstys.lt-key.pem:${acme.keyFile}"
          ];
        };
        preStart = ''
          ln -sf $CREDENTIALS_DIRECTORY/irc.jakstys.lt-cert.pem /run/soju/cert.pem
          ln -sf $CREDENTIALS_DIRECTORY/irc.jakstys.lt-key.pem /run/soju/key.pem
        '';
        after = [ "nsd-acme-irc.jakstys.lt.service" ];
        requires = [ "nsd-acme-irc.jakstys.lt.service" ];
      };

    syncthing-relay.restartIfChanged = false;

  };

  environment.systemPackages = with pkgs; [
    yt-dlp
    ffmpeg
    imapsync
    geoipWithDatabase
  ];

  networking = {
    hostId = "f9117e1b";
    hostName = "vno1-oh2";
    domain = "servers.jakst";
    defaultGateway = "192.168.189.4";
    nameservers = [ "192.168.189.4" ];
    interfaces.enp0s21f0u2.ipv4.addresses = [
      {
        address = "192.168.189.1";
        prefixLength = 24;
      }
    ];
    firewall = {
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
      rejectPackets = true;
    };
  };
}

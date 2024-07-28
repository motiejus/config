{
  lib,
  config,
  myData,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = ["scsi-0QEMU_QEMU_HARDDISK_36151096"];
      immutable = false;
      availableKernelModules = ["xhci_pci" "virtio_pci" "virtio_scsi" "usbhid" "sr_mod" "virtio_gpu"];
      removableEfi = true;
      kernelParams = ["console=tty"];
      sshUnlock = {
        enable = true;
        authorizedKeys =
          (builtins.attrValues myData.people_pubkeys)
          ++ [
            myData.hosts."vno1-oh2.servers.jakst".publicKey
          ];
      };
    };
  };

  mj = {
    stateVersion = "23.05";
    timeZone = "UTC";
    username = "motiejus";

    base = {
      users = {
        enable = true;
        root.hashedPasswordFile = config.age.secrets.root-passwd-hash.path;
        user.hashedPasswordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };

      snapshot = {
        enable = true;
        mountpoints = ["/var/lib"];
      };
    };

    services = {
      node_exporter.enable = true;
      sshguard.enable = true;
      tailscale.enable = true;

      remote-builder.server = {
        enable = true;
        uidgid = myData.uidgid.remote-builder;
        sshAllowSubnet = myData.subnets.tailscale.sshPattern;
        publicKeys = map (h: myData.hosts.${h}.publicKey) [
          "vno1-oh2.servers.jakst"
          "fwminex.motiejus.jakst"
          "mtworx.motiejus.jakst"
        ];
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          publicKeys = [
            myData.hosts."vno1-oh2.servers.jakst".publicKey
            myData.hosts."fwminex.motiejus.jakst".publicKey
          ];

          enable = true;
          sshAllowSubnets = [myData.subnets.tailscale.sshPattern];
          uidgid = myData.uidgid.updaterbot-deployee;
        };
      };

      zfsunlock = {
        enable = false;
        targets."vno1-oh2.servers.jakst" = let
          host = myData.hosts."vno1-oh2.servers.jakst";
        in {
          sshEndpoint = host.publicIP;
          pingEndpoint = host.jakstIP;
          remotePubkey = host.initrdPubKey;
          pwFile = config.age.secrets.zfs-passphrase-vno1-oh2.path;
          startAt = "*-*-* *:00/5:00";
        };
      };
    };
  };

  services = {
    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      globalConfig = ''
        servers {
          metrics
        }
      '';
      virtualHosts = {
        "www.11sync.net".extraConfig = ''
          redir https://jakstys.lt/2024/11sync-shutdown/
        '';
        "11sync.net".extraConfig = lib.mkForce ''
          redir https://jakstys.lt/2024/11sync-shutdown/
        '';
      };
    };

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
        "11sync.net.".data = myData.e11syncZone;
      };
    };
  };

  networking = {
    hostId = "bed6fa0b";
    hostName = "fra1-a";
    domain = "servers.jakst";
    useDHCP = true;
    firewall = {
      allowedUDPPorts = [53 443];
      allowedTCPPorts = [22 53 80 443];
    };
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}

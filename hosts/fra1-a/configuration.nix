{
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
      forceNoDev2305 = true;
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
    base = {
      users.passwd = {
        root.passwordFile = config.age.secrets.root-passwd-hash.path;
        motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
      };
      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      node_exporter.enable = true;
      sshguard.enable = true;
      tailscale = {
        enable = true;
        silenceLogs = true;
      };

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          inherit (myData.hosts."vno1-oh2.servers.jakst".publicKey);

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

  services.nsd = {
    enable = true;
    interfaces = ["0.0.0.0" "::"];
    zones = {
      "jakstys.lt.".data = myData.jakstysLTZone;
    };
  };

  networking = {
    hostId = "bed6fa0b";
    hostName = "fra1-a";
    domain = "servers.jakst";
    useDHCP = true;
    firewall = {
      allowedUDPPorts = [53];
      allowedTCPPorts = [22 53];
    };
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}

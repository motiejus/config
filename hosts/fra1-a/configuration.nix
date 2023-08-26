{
  config,
  pkgs,
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
            myData.hosts."hel1-a.servers.jakst".publicKey
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

      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      deployerbot = {
        follower = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          publicKey = myData.hosts."vno1-oh2.servers.jakst".publicKey;
        };
      };
    };
  };

  services.tailscale.enable = true;

  networking = {
    hostId = "bed6fa0b";
    hostName = "fra1-a";
    domain = "servers.jakst";
    useDHCP = true;
    firewall = {
      allowedUDPPorts = [];
      allowedTCPPorts = [22];
      checkReversePath = "loose"; # for tailscale
    };
  };

  nixpkgs.hostPlatform = "aarch64-linux";
}

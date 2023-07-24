{
  config,
  pkgs,
  myData,
  ...
}: {
  zfs-root = {
    boot = {
      enable = true;
      devNodes = "/dev/disk/by-id/";
      bootDevices = ["nvme-Samsung_SSD_970_EVO_Plus_2TB_S6P1NX0TA00913P"];
      immutable = false;
      availableKernelModules = ["ahci" "xhci_pci" "nvme" "usbhid" "sdhci_pci" "r8169"];
      removableEfi = true;
      kernelParams = [
        "ip=192.168.189.1::192.168.189.4:255.255.255.0:vno1-oh2.jakstys.lt:enp3s0:off"
      ];
      sshUnlock = {
        enable = true;
        authorizedKeys =
          (builtins.attrValues myData.people_pubkeys)
          ++ [myData.hosts."hel1-a.servers.jakst".publicKey];
      };
    };
  };

  mj = {
    stateVersion = "23.05";
    timeZone = "Europe/Vilnius";

    base = {
      users.passwd = {
        root.passwordFile = config.age.secrets.root-passwd-hash.path;
        motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
      };
    };

    services.zfsunlock = {
      enable = true;
      targets."hel1-a.servers.jakst" = {
         sshEndpoint = myData.ips.hel1a;
         pingEndpoint = "hel1-a.servers.jakst";
         remotePubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEzt0eaSRTAfM2295x4vACEd5VFqVeYJPV/N9ZUq+voP";
         pwFile = config.age.secrets.zfs-passphrase-hel1-a.path;
         startAt = "*-*-* *:00/5:00";
      };
    };
  };

  services = {
    tailscale.enable = true;

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
    };

    zfs = {
      autoScrub.enable = true;
      trim.enable = true;
      expandOnBoot = "all";
    };
  };

  networking = {
    hostId = "f9117e1b";
    hostName = "vno1-oh2";
    domain = "jakstys.lt";
    defaultGateway = "192.168.189.4";
    nameservers = ["192.168.189.4"];
    interfaces.enp3s0.ipv4.addresses = [
      {
        address = "192.168.189.1";
        prefixLength = 24;
      }
    ];
  };
}

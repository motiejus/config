{
  config,
  pkgs,
  myData,
  ...
}:
let
  nvme = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7DNNU0Y624491Y";

  # iPXE boot menu script
  ipxeMenu = pkgs.writeText "boot.ipxe" ''
    #!ipxe

    :menu
    menu PXE Boot Menu
    item mrescue Boot mrescue (Rescue System)
    item netbootxyz Boot netboot.xyz
    item shell iPXE Shell
    choose --default mrescue --timeout 10000 selected || goto menu
    goto ''${selected}

    :mrescue
    kernel http://10.14.143.1/boot/mrescue/kernel
    initrd http://10.14.143.1/boot/mrescue/initrd
    boot

    :netbootxyz
    chain http://10.14.143.1/boot/netboot.xyz.efi

    :shell
    shell
  '';

  # Custom iPXE with embedded menu
  customIpxe = pkgs.ipxe.override {
    embedScript = ipxeMenu;
  };

  # TFTP root directory with all boot files
  tftp-root = pkgs.runCommand "tftp-root" { } ''
    mkdir -p $out/mrescue
    cp ${customIpxe}/ipxe.efi $out/boot.efi
    cp ${pkgs.mrescue}/kernel $out/mrescue/kernel
    cp ${pkgs.mrescue}/initrd $out/mrescue/initrd
    cp ${pkgs.netbootxyz-efi} $out/netboot.xyz.efi
  '';
in
{
  imports = [
    ../../shared/work
    ../../modules
    ../../modules/profiles/workstation
    ../../modules/profiles/autorandr
    ../../modules/profiles/btrfs
  ];

  age.secrets = {
    motiejus-work-passwd-hash.file = ../../secrets/motiejus_work_passwd_hash.age;
    root-work-passwd-hash.file = ../../secrets/root_work_passwd_hash.age;
    sasl-passwd.file = ../../secrets/postfix_sasl_passwd.age;

    syncthing-key.file = ../../secrets/mtworx/syncthing/key.pem.age;
    syncthing-cert.file = ../../secrets/mtworx/syncthing/cert.pem.age;
    kolide-launcher.file = ../../secrets/mtworx/kolide-launcher.age;
    s1-site-token.file = ../../secrets/mtworx/s1-site-token.age;

    ssh8022-client = {
      file = ../../secrets/ssh8022.age;
      mode = "444";
    };
  };

  boot = {
    kernelPackages = pkgs.linuxPackages_6_18;
    loader.systemd-boot.netbootxyz.enable = true;

    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usbhid"
        "tpm_tis"
      ];

      systemd.emergencyAccess = true;
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

  hardware.coral.usb.enable = true;

  hardware.cpu.intel.updateMicrocode = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  mj = {
    profiles.desktop.enableUserServices = true;
    stateVersion = "23.11";
    timeZone = "UTC";
    username = "motiejus";

    base.users = {
      enable = true;
      devTools = true;
      root.hashedPasswordFile = config.age.secrets.root-work-passwd-hash.path;
      user.hashedPasswordFile = config.age.secrets.motiejus-work-passwd-hash.path;
    };

    services = {
      sentinelone = {
        enable = true;
        customerId = "motiejus.jakstys@chronosphere.io-mtworx";
        sentinelOneManagementTokenPath = config.age.secrets.s1-site-token.path;
      };

      ssh8022.client = {
        enable = true;
        keyfile = config.age.secrets.ssh8022-client.path;
      };

      tailscale = {
        enable = true;
        verboseLogs = true;
        acceptDNS = true;
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

      node_exporter = {
        enable = true;
        extraSubnets = [ myData.subnets.vno1.cidr ];
      };

      deployerbot = {
        follower = {
          publicKeys = [ myData.hosts."fwminex.jakst.vpn".publicKey ];

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

  systemd.services = {
    nginx.serviceConfig.BindPaths = [ "/home/motiejus/www:/var/run/nginx/motiejus" ];
  };

  services = {

    nginx = {
      enable = true;
      defaultListenAddresses = [ "0.0.0.0" ];
      virtualHosts = {
        "_" = {
          default = true;
          root = "/var/run/nginx/motiejus";
          locations."/".extraConfig = ''
            autoindex on;
          '';
          locations."/boot/" = {
            alias = "${tftp-root}/";
            extraConfig = ''
              autoindex on;
            '';
          };
        };
        "go" = {
          addSSL = true;
          sslCertificate = "${../../shared/certs/go.pem}";
          sslCertificateKey = "${../../shared/certs/go.key}";
          locations."/".extraConfig = ''
            return 301 https://golinks.io$request_uri;
          '';
        };
      };
    };

    tlp = {
      enable = true;
      settings = {
        START_CHARGE_THRESH_BAT0 = 80;
        STOP_CHARGE_THRESH_BAT0 = 87;
      };
    };
    kolide-launcher.enable = true;

    dnsmasq = {
      enable = true;
      settings = {
        dhcp-range = [ "10.14.143.100,10.14.143.200" ];
        dhcp-option = "66,\"0.0.0.0\"";
        enable-tftp = true;
        tftp-root = "${tftp-root}";
        dhcp-boot = "boot.efi";
      };
    };
  };

  users.extraGroups.vboxusers.members = [ "motiejus" ];

  environment = {
    systemPackages = with pkgs; [
      dnsmasq
      OVMF
    ];
    etc."kolide-k2/secret" = {
      mode = "600";
      source = config.age.secrets.kolide-launcher.path;
    };
  };

  security.tpm2.enable = true;

  networking = {
    hostId = "b14a02aa";
    hostName = "mtworx";
    domain = "jakst.vpn";

    bridges.br0 = {
      interfaces = [ ];
    };

    # Configure bridge with internal IP
    interfaces.br0 = {
      ipv4.addresses = [
        {
          address = "10.14.143.1";
          prefixLength = 24;
        }
      ];
    };

    nat = {
      enable = true;
      externalInterface = "wlp0s20f3";
      internalInterfaces = [ "br0" ];
      internalIPs = [ "10.14.143.0/24" ];
    };

    firewall = {
      rejectPackets = true;
      interfaces.br0 = {
        allowedUDPPorts = [
          53 # DNS
          67 # DHCP
          69 # TFTP
        ];
        allowedTCPPorts = [
          53 # DNS
          80 # HTTP for boot files
        ];
      };
      extraCommands = ''
        # Allow only through WiFi interface (to gateway and internet)
        iptables -A FORWARD -s 10.14.143.0/24 -o wlp0s20f3 -j ACCEPT

        # Allow established connections back
        iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

        # Block everything else from 10.14.143.0/24
        iptables -A FORWARD -s 10.14.143.0/24 -j DROP
      '';
    };
  };
}

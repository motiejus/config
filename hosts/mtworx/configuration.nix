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

    # Ensure network is configured
    dhcp || echo DHCP failed, trying to continue anyway

    :menu
    menu PXE Boot Menu
    item debian-shell-toram Boot Debian Live ${pkgs.mrescue-debian-xfce.version} (Shell) to RAM
    item debian-shell-nfs Boot Debian Live ${pkgs.mrescue-debian-xfce.version} (Shell) via NFS
    item debian-xfce-toram Boot Debian Live ${pkgs.mrescue-debian-xfce.version} (XFCE) to RAM
    item debian-xfce-nfs Boot Debian Live ${pkgs.mrescue-debian-xfce.version} (XFCE) via NFS
    item nixos Boot NixOS ${pkgs.mrescue-nixos.version}
    item alpine Boot Alpine Linux ${pkgs.mrescue-alpine.version}
    item netbootxyz Boot netboot.xyz
    item shell iPXE Shell
    item tips mrescue tips
    choose --default debian-shell-toram --timeout 10000 selected || goto menu
    goto ''${selected}

    :debian-shell-toram
    kernel http://10.14.143.1/boot/debian-xfce/live/vmlinuz boot=live components fetch=http://10.14.143.1/boot/debian-xfce/live/filesystem.squashfs systemd.unit=multi-user.target ''${cmdline}
    initrd http://10.14.143.1/boot/debian-xfce/live/initrd.img
    boot

    :debian-shell-nfs
    kernel http://10.14.143.1/boot/debian-xfce/live/vmlinuz boot=live components netboot=nfs nfsroot=10.14.143.1:/srv/boot/debian-xfce systemd.unit=multi-user.target ''${cmdline}
    initrd http://10.14.143.1/boot/debian-xfce/live/initrd.img
    boot

    :debian-xfce-toram
    kernel http://10.14.143.1/boot/debian-xfce/live/vmlinuz boot=live components fetch=http://10.14.143.1/boot/debian-xfce/live/filesystem.squashfs ''${cmdline}
    initrd http://10.14.143.1/boot/debian-xfce/live/initrd.img
    boot

    :debian-xfce-nfs
    kernel http://10.14.143.1/boot/debian-xfce/live/vmlinuz boot=live components netboot=nfs nfsroot=10.14.143.1:/srv/boot/debian-xfce ''${cmdline}
    initrd http://10.14.143.1/boot/debian-xfce/live/initrd.img
    boot

    :nixos
    # kernel params copied from https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/netboot-x86_64-linux.ipxe
    kernel http://10.14.143.1/boot/nixos/kernel init=/nix/store/lillmv6sbjxgyyyn1ilkica21q3hmpya-nixos-system-nixos-kexec-25.11beta-193477.gfedcba/init initrd=initrd-x86_64-linux nohibernate loglevel=4 lsm=landlock,yama,bpf ''${cmdline}
    initrd http://10.14.143.1/boot/nixos/initrd
    boot

    :alpine
    kernel http://10.14.143.1/boot/alpine/kernel ''${cmdline}
    initrd http://10.14.143.1/boot/alpine/initrd
    boot

    :netbootxyz
    isset ''${platform} && iseq ''${platform} pcbios && chain --autofree https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe ||
    chain --autofree https://boot.netboot.xyz/ipxe/netboot.xyz.efi

    :shell
    shell
    goto menu

    :tips
    echo
    echo To add kernel command line arguments:
    echo   1. Select 'iPXE Shell' from menu
    echo   2. Run: set cmdline systemd.unit=multi-user.target
    echo   3. Type 'exit' to return to menu
    echo   4. Select your OS to boot with custom args
    echo
    echo More useful commands:
    echo  set cmdline console=ttyS0
    echo
    prompt Press any key to return to menu...
    goto menu
  '';

  # Custom iPXE with embedded menu (UEFI)
  customIpxeEfi = pkgs.ipxe.override {
    embedScript = ipxeMenu;
  };

  # Custom iPXE with embedded menu (BIOS)
  customIpxeBios = pkgs.ipxe.override {
    embedScript = ipxeMenu;
  };

  # TFTP root directory with all boot files
  tftp-root = pkgs.runCommand "tftp-root" { } ''
    mkdir -p $out/alpine
    mkdir -p $out/debian-xfce
    mkdir -p $out/nixos

    cp ${customIpxeEfi}/ipxe.efi $out/boot.efi
    cp ${customIpxeBios}/undionly.kpxe $out/boot.kpxe

    # Alpine
    cp ${pkgs.mrescue-alpine}/kernel $out/alpine/kernel
    cp ${pkgs.mrescue-alpine}/initrd $out/alpine/initrd

    # Debian XFCE (full ISO contents)
    cp -r ${pkgs.mrescue-debian-xfce}/* $out/debian-xfce/

    # NixOS
    cp ${pkgs.mrescue-nixos}/kernel $out/nixos/kernel
    cp ${pkgs.mrescue-nixos}/initrd $out/nixos/initrd
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
    "/srv/boot" = {
      device = "${tftp-root}";
      fsType = "none";
      options = [
        "bind"
        "ro"
      ];
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

    nfs.server = {
      enable = true;
      mountdPort = 20048;
      lockdPort = 32803;
      statdPort = 32764;
      exports = ''
        /srv/boot 10.14.143.0/24(ro,no_subtree_check,no_root_squash,insecure) localhost(ro,no_subtree_check,no_root_squash,insecure)
      '';
    };

    dnsmasq = {
      enable = true;
      settings = {
        dhcp-range = [ "10.14.143.100,10.14.143.200" ];
        dhcp-option = "66,\"0.0.0.0\"";
        enable-tftp = true;
        tftp-root = "${tftp-root}";
        interface = "br0";

        dhcp-match = [
          "set:efi-x86_64,option:client-arch,7" # EFI BC (x86-64)
          "set:efi-x86_64,option:client-arch,9" # EFI x86-64
          "set:efi-x86,option:client-arch,6" # EFI IA32
          "set:bios,option:client-arch,0" # BIOS x86
        ];

        dhcp-boot = [
          "tag:efi-x86_64,boot.efi" # UEFI x86-64 clients
          "tag:efi-x86,boot.efi" # UEFI IA32 clients
          "tag:bios,boot.kpxe" # BIOS clients
          "boot.efi" # Default to UEFI if undetected
        ];
      };
    };
  };

  users.extraGroups.vboxusers.members = [ "motiejus" ];

  environment = {
    systemPackages = with pkgs; [
      OVMF
      libnfs # nfs-ls
      dnsmasq
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
        allowedTCPPorts = [
          53 # DNS
          80 # HTTP for boot files
          111 # rpcbind
          2049 # NFS
          20048 # mountd
          32803 # lockd
          32764 # statd
        ];
        allowedUDPPorts = [
          53 # DNS
          67 # DHCP
          69 # TFTP
          111 # rpcbind
          20048 # mountd
          32803 # lockd
          32764 # statd
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

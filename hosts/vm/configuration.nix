{
  self,
  lib,
  pkgs,
  config,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/profiles/all-hardware.nix"
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
    ../../modules/profiles/desktop
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.nixos = {pkgs, ...}:
    lib.mkMerge [
      (import ../../shared/home/default.nix {
        inherit lib;
        inherit pkgs;
        inherit (config.mj) stateVersion;
        username = "nixos";
        devTools = true;
        hmOnly = false;
        email = "motiejus@jakstys.lt";
      })
      {
        programs.bash = {
          enable = true;
          shellAliases = {
            "l" = "echo -n ł | xclip -selection clipboard";
            "gp" = "${pkgs.git}/bin/git remote | ${pkgs.parallel}/bin/parallel --verbose git push";
          };
        };
      }
    ];

  mj = {
    stateVersion = "23.11";
    timeZone = "UTC";
    desktop = {
      username = "nixos";
      configureDM = false;
    };
  };

  isoImage = {
    isoName = "toolshed-${self.lastModifiedDate}.iso";
    squashfsCompression = "zstd";
    appendToMenuLabel = " Toolshed ${self.lastModifiedDate}";
    makeEfiBootable = true; # EFI booting
    makeUsbBootable = true; # USB booting
  };

  boot.kernelPackages = pkgs.zfs.latestCompatibleLinuxPackages;

  swapDevices = [];

  services = {
    pcscd.enable = true;
    getty.autologinUser = "nixos";
    xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
      displayManager = {
        lightdm.enable = true;
        autoLogin = {
          enable = true;
          user = "nixos";
        };
      };
    };
  };

  programs = {
    ssh.startAgent = false;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };

  users.users = {
    nixos = {
      isNormalUser = true;
      extraGroups = ["wheel" "video"];
      initialHashedPassword = "";
    };
    root.initialHashedPassword = "";
  };

  security = {
    pam.services.lightdm.text = ''
      auth sufficient pam_succeed_if.so user ingroup wheel
    '';
    sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };
  };

  networking = {
    hostName = "vm";
    domain = "example.org";
    firewall.allowedTCPPorts = [22];
  };

  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
      trusted-users = vm
    '';
  };
}

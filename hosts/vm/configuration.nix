{
  lib,
  self,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    "${modulesPath}/profiles/all-hardware.nix"
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
    ../../modules
    ../../modules/profiles/btrfs
    ../../modules/profiles/desktop
  ];

  mj = {
    stateVersion = "24.11";
    timeZone = "UTC";
    username = "nixos";

    base.users = {
      enable = true;
      user.initialHashedPassword = "";
      root.initialHashedPassword = "";
    };
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  isoImage = {
    isoName = "toolshed-${self.lastModifiedDate}.iso";
    squashfsCompression = "zstd";
    appendToMenuLabel = " Toolshed ${self.lastModifiedDate}";
    makeEfiBootable = true; # EFI booting
    makeUsbBootable = true; # USB booting
  };

  swapDevices = [ ];

  services = {
    getty.autologinUser = "nixos";
    autorandr.enable = true;
    xserver = {
      autorun = false;
      displayManager.defaultSession = lib.mkForce "xfce";
    };
  };

  security.pam.services.lightdm.text = ''
    auth sufficient pam_succeed_if.so user ingroup wheel
  '';

  networking = {
    hostName = "vm";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [ 22 ];
    hostId = "abefef01";
  };
}

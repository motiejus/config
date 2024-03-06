{
  self,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    "${modulesPath}/profiles/all-hardware.nix"
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  mj = {
    stateVersion = "23.11";
    timeZone = "UTC";
    username = "nixos";

    base.users = {
      enable = true;
      user.initialHashedPassword = "";
      root.initialHashedPassword = "";
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
    getty.autologinUser = "nixos";
  };

  # do not autostart lightdm, leave at tty
  systemd.services.display-manager.wantedBy = lib.mkForce [];

  security.pam.services.lightdm.text = ''
    auth sufficient pam_succeed_if.so user ingroup wheel
  '';

  networking = {
    hostName = "vm";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [22];
  };
}

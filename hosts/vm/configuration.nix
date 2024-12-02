{
  lib,
  modulesPath,
  pkgs,
  config,
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

  isoImage =
    let
      vsn = "${config.system.nixos.release}${lib.trivial.versionSuffix}";
    in
    {
      isoName = "toolshed-${vsn}.iso";
      squashfsCompression = "zstd";
      appendToMenuLabel = " Toolshed ${vsn}";
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

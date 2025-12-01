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
    stateVersion = "25.05";
    timeZone = "UTC";
    username = "nixos";

    base.users = {
      enable = true;
      user.initialHashedPassword = "";
      root.initialHashedPassword = "";
    };
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  image =
    let
      vsn = "${config.system.nixos.release}${lib.trivial.versionSuffix}";
    in
    {
      fileName = "toolshed-${vsn}.iso";
    };

  isoImage = {
    # as of writing zstd -19 reduces toolshed from 9.1G to 8.6G, but takes
    # ~30min on fwminex, as opposed to ~10m with default settings. xz also
    # yields 8.6G.
    #squashfsCompression = "zstd -Xcompression-level 19";
    squashfsCompression = "zstd";
    appendToMenuLabel = " Toolshed ${config.system.nixos.release}${lib.trivial.versionSuffix}";
    makeEfiBootable = true; # EFI booting
    makeUsbBootable = true; # USB booting
  };

  swapDevices = [ ];

  services = {
    getty.autologinUser = "nixos";
    autorandr.enable = true;
    xserver.autorun = false;
    displayManager.defaultSession = lib.mkForce "xfce";
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

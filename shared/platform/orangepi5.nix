{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
in {
  boot = {
    kernelPackages = crossPkgs.linuxPackagesFor (crossPkgs.buildLinux {
      version = "6.8.0-rc1";
      modDirVersion = "6.8.0-rc1";

      #src = linux-rockchip-collabora;
      #src = builtins.fetchUrl {
      #  url = "https://git.jakstys.lt/motiejus/linux/archive/rk3588.tar.gz";
      #  sha256 = "869adb5236254e705b51f3bcd22c0ac2498ca661c44c5a25a737bb067bc5a635";
      #};
      src = builtins.fetchGit {
        url = "https://git.jakstys.lt/motiejus/linux";
        rev = "eadcef24731e0f1ddb86dc7c9c859387b5b029a2";
        ref = "rk3588";
        shallow = true;
      };
      kernelPatches = [];

      extraMeta.branch = "6.8";
    });

    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    initrd.kernelModules = ["ahci_dwc" "phy_rockchip_naneng_combphy"];
    consoleLogLevel = 7;
  };

  hardware.deviceTree.name = "rockchip/rk3588s-orangepi-5-plus.dtb";

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      options = ["noatime"];
    };
  };

  system.build = {
    sdImage = import "${modulesPath}/../lib/make-disk-image.nix" {
      name = "orangepi5-sd-image";
      copyChannel = false;
      inherit config lib pkgs;
    };
    uboot = crossPkgs.callPackage ../../hacks/orangepi5/uboot {};
  };
}

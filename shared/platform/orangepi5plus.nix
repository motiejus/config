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
    kernelPackages = crossPkgs.linuxPackagesFor (crossPkgs.buildLinux rec {
      version = "6.8.0-rc1";
      modDirVersion = "6.8.0-rc1";

      src = builtins.fetchTarball {
        url = "https://git.kernel.org/torvalds/t/linux-6.8-rc1.tar.gz";
        sha256 = "0rnrd1iy73vkrablx6rqlmxv9bv9zjfh6zj09aqca9rr5h8iz1p3";
      };
      kernelPatches = [
        {
          name = "orangepi-5-plus-collabora-${version}";
          patch = ./orangepi5plus/rk3588-v${version}.patch;
        }
      ];

      extraMeta.branch = "6.8";
    });

    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    initrd.kernelModules = ["ahci_dwc" "phy_rockchip_naneng_combphy"];
    consoleLogLevel = 7;
  };

  hardware.deviceTree.name = "rockchip/rk3588-orangepi-5-plus.dtb";

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
    uboot = crossPkgs.callPackage ../../hacks/orangepi5plus/uboot {};
  };
}

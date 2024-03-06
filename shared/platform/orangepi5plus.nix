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
      version = "6.8.0-rc7";
      modDirVersion = "6.8.0-rc7";

      src = builtins.fetchTarball {
        url = "https://git.kernel.org/torvalds/t/linux-6.8-rc7.tar.gz";
        sha256 = "sha256:0q9isgv6lxzrmb4idl0spxv2l7fsk3nn4cdq0vdw9c8lyzrh5yy0";
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

  system.build = {
    sdImage = import "${modulesPath}/../lib/make-disk-image.nix" {
      name = "orangepi5-sd-image";
      copyChannel = false;
      inherit config lib pkgs;
    };
    uboot = crossPkgs.callPackage ../../hacks/orangepi5plus/uboot {};
  };
}

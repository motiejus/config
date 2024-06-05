{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
#let
#crossFast = pkgs.crossArm64.pkgsCross.aarch64-multiplatform;
#in
{
  mj.skipPerf = true;

  boot = {
    #kernelPackages = crossNative.linuxPackagesFor (crossFast.buildLinux rec {
    kernelPackages = pkgs.linuxPackagesFor (pkgs.buildLinux rec {
      version = "6.9.0-rc1";
      modDirVersion = "6.9.0-rc1";

      src = builtins.fetchTarball {
        url = "https://github.com/torvalds/linux/archive/refs/tags/v6.9-rc1.tar.gz";
        # "unsupported snapshot format" 2024-05-06
        #url = "https://git.kernel.org/torvalds/t/linux-6.9-rc1.tar.gz";
        #url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.8.tar.xz";
        sha256 = "sha256:05hi2vfmsjwl5yhqmy4h5a954090nv48z9gabhvh16xlaqlfh8nz";
      };
      kernelPatches = [
        {
          name = "orangepi-5-plus-collabora-${version}";
          patch = ./orangepi5plus/rk3588-v6.9-rc1.patch;
        }
        {
          name = "rk3588-crypto";
          patch = ./orangepi5plus/rk3588-crypto.patch;
        }
      ];
      extraConfig = ''
        CRYPTO_DEV_ROCKCHIP2 m
        CRYPTO_DEV_ROCKCHIP2_DEBUG y
      '';

      extraMeta.branch = "6.9";
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
    #uboot = crossFast.callPackage ../../hacks/orangepi5plus/uboot {};
    uboot = pkgs.callPackage ../../hacks/orangepi5plus/uboot {};
  };
}

{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  crossFast = pkgs.crossArm64.pkgsCross.aarch64-multiplatform;
  crossNative = pkgs.pkgsCross.aarch64-multiplatform;
in {
  mj.skipPerf = true;

  boot = {
    kernelPackages = crossNative.linuxPackagesFor (crossFast.buildLinux rec {
      version = "6.8.0";
      modDirVersion = "6.8.0";

      src = builtins.fetchTarball {
        #url = "https://git.kernel.org/torvalds/t/linux-6.8-rc7.tar.gz";
        url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.8.tar.xz";
        sha256 = "sha256:1xzi1yhh5k3vzfwvw4f2rzaas6dh4qara33vzj77xiz2zmks2y5d";
      };
      kernelPatches = [
        {
          name = "orangepi-5-plus-collabora-${version}";
          patch = ./orangepi5plus/rk3588-v6.8.patch;
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
    uboot = crossFast.callPackage ../../hacks/orangepi5plus/uboot {};
  };
}

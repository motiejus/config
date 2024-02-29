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
    kernelPackages = let
      branch = "6.8";
      version = "${branch}-rc1";
    in
      crossPkgs.linuxPackagesFor (crossPkgs.buildLinux {
        inherit version;
        modDirVersion = version;

        src = builtins.fetchTarball {
          url = "https://git.kernel.org/torvalds/t/linux-${version}.tar.gz";
          sha256 = "0rnrd1iy73vkrablx6rqlmxv9bv9zjfh6zj09aqca9rr5h8iz1p3";
        };
        kernelPatches = [
          {
            name = "orangepi-5-plus-collabora-v${version}";
            patch = ./orangepi5plus/rk3588-v${version}.patch;
          }
        ];

        extraMeta.branch = branch;
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

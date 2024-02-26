{
  config,
  lib,
  pkgs,
  pkgsHost,
  inputs,
  ...
}: let
  crossPkgs = pkgsHost.pkgsCross.aarch64-multiplatform;
in {
  boot = {
    kernelPackages = crossPkgs.linuxPackagesFor (crossPkgs.buildLinux {
      version = "6.8.0-rc1";
      modDirVersion = "6.8.0-rc1";

      src = inputs.linux-rockchip-collabora;
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

  hardware = {
    deviceTree.name = "rockchip/rk3588s-orangepi-5.dtb";

    opengl.package = let
      mesa = pkgs.callPackage ../../hacks/orangepi5/mesa {
        galliumDrivers = ["panfrost"];
        vulkanDrivers = ["panfrost"];
        OpenGL = null;
        Xplugin = null;
        enableGalliumNine = false;
        enableOSMesa = false;
        enableVaapi = false;
        enableVdpau = false;
        enableXa = false;
      };
      mesa-panthor = mesa.overrideAttrs (_: {
        src = inputs.mesa-panthor;
      });
    in
      mesa-panthor.drivers;
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      options = ["noatime"];
    };
  };

  system.build = {
    sdImage = import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix" {
      name = "orangepi5-sd-image";
      copyChannel = false;
      inherit config lib pkgs;
    };
    uboot = crossPkgs.callPackage ../../hacks/orangepi5/uboot {};
  };
}

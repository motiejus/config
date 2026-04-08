{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.profiles.btrfs;
in
{
  options.mj.profiles.btrfs = with lib.types; {
    disk = lib.mkOption {
      type = nullOr str;
      default = null;
      example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_...";
      description = "Disk device path for LUKS+BTRFS layout (part1=boot, part2=swap, part3=luks root)";
    };
    luksExtraConfig = lib.mkOption {
      type = attrs;
      default = { };
      description = "Extra config merged into boot.initrd.luks.devices.luksroot";
    };
  };

  config = lib.mkMerge [
    {
      boot.supportedFilesystems = [ "btrfs" ];
      environment.systemPackages = [ pkgs.btrfs-auto-snapshot ];
    }

    (lib.mkIf (cfg.disk != null) {
      boot.initrd.luks.devices.luksroot = {
        device = "${cfg.disk}-part3";
        allowDiscards = true;
      }
      // cfg.luksExtraConfig;

      fileSystems = {
        "/" = {
          device = "/dev/mapper/luksroot";
          fsType = "btrfs";
          options = [ "compress=zstd" ];
        };
        "/boot" = {
          device = "${cfg.disk}-part1";
          fsType = "vfat";
        };
      };

      swapDevices = [
        {
          device = "${cfg.disk}-part2";
          randomEncryption.enable = true;
        }
      ];
    })
  ];
}

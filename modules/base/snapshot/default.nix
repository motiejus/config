{ config, lib, ... }:
{
  options.mj.base.snapshot = {
    enable = lib.mkEnableOption "Enable zfs snapshots";

    mountpoints = lib.mkOption {
      default = { };
      type = with lib.types; listOf str;
    };
  };

  config = lib.mkIf config.mj.base.snapshot.enable {
    services.sanoid = {
      enable = true;
      templates.prod = {
        hourly = 24;
        daily = 7;
        autosnap = true;
        autoprune = true;
      };
      extraArgs = [ "--verbose" ];
      datasets =
        let
          fs_zfs = lib.filterAttrs (_: v: v.fsType == "zfs") config.fileSystems;
          mountpoint2fs = builtins.listToAttrs (
            map (mountpoint: {
              name = mountpoint;
              value = builtins.getAttr mountpoint fs_zfs;
            }) config.mj.base.snapshot.mountpoints
          );
          s_datasets = lib.mapAttrs' (_mountpoint: fs: {
            name = fs.device;
            value = {
              use_template = [ "prod" ];
            };
          }) mountpoint2fs;
        in
        s_datasets;
    };
  };
}

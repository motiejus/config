{
  config,
  lib,
  ...
}: {
  options.mj.base.zfs = with lib.types; {
    enable = lib.mkEnableOption "Enable common zfs options";
  };

  config = lib.mkIf config.mj.base.zfs.enable {
    services.zfs = assert lib.assertMsg config.mj.base.unitstatus.enable "mj.base.unitstatus must be enabled"; {
      autoScrub.enable = true;
      trim.enable = true;
      expandOnBoot = "all";
    };

    mj.base.unitstatus.units = ["zfs-scrub"];
  };
}

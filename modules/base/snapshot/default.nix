{
  config,
  lib,
  myData,
  ...
}:
with lib; {
  options.mj.base.snapshot = {
    enable = mkEnableOption "Enable zfs snapshots";

    pools = mkOption {
      default = {};
      type = with types;
        attrsOf (submodule (
          {...}: {
            options = {
              mountpoint = mkOption {type = str;};
              zfs_name = mkOption {type = str;};
              #paths = mkOption { type = listOf str; };
              #backup_at = mkOption { type = str; };
            };
          }
        ));
    };
  };

  config = with config.mj.base.snapshot;
    mkIf enable {
      sanoid = {
        enable = true;
        templates.prod = {
          hourly = 24;
          daily = 7;
          autosnap = true;
          autoprune = true;
        };
        datasets =
          lib.mapAttrs' (name: value: {
            name = value.zfs_name;
            value = {use_template = ["prod"];};
          })
          pools;
        extraArgs = ["--verbose"];
      };
    };
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.btrfssnapshot;
in
{
  options.mj.services.btrfssnapshot = {
    enable = lib.mkEnableOption "Enable btrfs snapshots";

    subvolumes = lib.mkOption {
      default = { };
      type =
        with lib.types;
        attrsOf (submodule {
          options = {
            label = lib.mkOption { type = str; };
            keep = lib.mkOption { type = int; };
            refreshInterval = lib.mkOption { type = str; };
          };
        });
    };
  };

  config = lib.mkIf cfg.enable {
    systemd = {
      services = lib.mapAttrs' (
        subvolume: params:
        lib.nameValuePair "btrfs-snapshot-${lib.strings.sanitizeDerivationName subvolume}" {
          description = "${params.label} btrfs snapshot for ${subvolume} (keep ${builtins.toString params.keep})";
          serviceConfig.ExecStart = "${pkgs.btrfs-auto-snapshot}/bin/btrfs-auto-snapshot --verbose --label=${params.label} --keep=${builtins.toString params.keep} ${subvolume}";
        }
      ) cfg.subvolumes;

      timers = lib.mapAttrs' (
        subvolume: params:
        lib.nameValuePair "btrfs-snapshot-${lib.strings.sanitizeDerivationName subvolume}" {
          description = "${params.label} btrfs snapshot for ${subvolume}";
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = params.refreshInterval;
        }
      ) cfg.subvolumes;
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.btrfssnapshot;
  svcName =
    subvol: label:
    "btrfs-snapshot-${lib.strings.sanitizeDerivationName subvol}-${lib.strings.sanitizeDerivationName label}";
in
{
  options.mj.services.btrfssnapshot = {
    enable = lib.mkEnableOption "Enable btrfs snapshots";

    subvolumes = lib.mkOption {
      default = { };
      type =
        with lib.types;
        listOf (submodule {
          options = {
            subvolume = lib.mkOption { type = str; };
            label = lib.mkOption { type = str; };
            keep = lib.mkOption { type = int; };
            refreshInterval = lib.mkOption { type = str; };
          };
        });
    };
  };

  config = lib.mkIf cfg.enable {
    systemd = {

      timers = lib.listToAttrs (
        map (
          params:
          lib.nameValuePair (svcName params.subvolume params.label) {
            description = "${params.label} btrfs snapshot for ${params.subvolume}";
            wantedBy = [ "timers.target" ];
            timerConfig.OnCalendar = params.refreshInterval;
          }
        ) cfg.subvolumes
      );

      services = lib.listToAttrs (
        map (
          params:
          lib.nameValuePair (svcName params.subvolume params.label) {
            description = "${params.label} btrfs snapshot for ${params.subvolume} (keep ${builtins.toString params.keep})";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = ''
                ${pkgs.btrfs-auto-snapshot}/bin/btrfs-auto-snapshot \
                              --verbose \
                              --label=${params.label} \
                              --keep=${builtins.toString params.keep} \
                              ${params.subvolume}'';
            };
          }
        ) cfg.subvolumes
      );

    };
  };
}

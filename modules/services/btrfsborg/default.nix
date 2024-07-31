{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.mj.services.btrfsborg;
in
{
  options.mj.services.btrfsborg = with lib.types; {
    enable = lib.mkEnableOption "backup zfs snapshots with borg";

    passwordPath = lib.mkOption { type = str; };
    sshKeyPath = lib.mkOption {
      type = nullOr path;
      default = null;
    };

    dirs = lib.mkOption {
      default = { };
      type = listOf (submodule {
        options = {
          subvolume = lib.mkOption { type = path; };
          repo = lib.mkOption { type = str; };
          paths = lib.mkOption { type = listOf str; };
          patterns = lib.mkOption {
            type = listOf str;
            default = [ ];
          };
          prune = lib.mkOption {
            type = anything;
            default = { };
          };
          backup_at = lib.mkOption { type = str; };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = lib.listToAttrs (
      lib.imap0 (
        i: attr:
        let
          svcName = "borgbackup-job-${lib.strings.sanitizeDerivationName attr.subvolume}-${toString i}";
        in
        lib.nameValuePair svcName { serviceConfig.RuntimeDirectory = svcName; }
      ) cfg.dirs
    );

    services.borgbackup.jobs = builtins.listToAttrs (
      lib.imap0 (
        i: attrs:
        let
          subvolume = builtins.getAttr "subvolume" attrs;
        in
        assert lib.assertMsg config.mj.base.unitstatus.enable
          "config.mj.base.unitstatus.enable must be true";
        lib.nameValuePair "${lib.strings.sanitizeDerivationName subvolume}-${toString i}" (
          {
            inherit (attrs) repo paths;

            doInit = true;
            encryption = {
              mode = "repokey-blake2";
              passCommand = "cat ${cfg.passwordPath}";
            };
            extraArgs = "--remote-path=borg1";
            compression = "auto,zstd,10";
            extraCreateArgs = "--chunker-params buzhash,10,23,16,4095";
            startAt = attrs.backup_at;
            preHook = ''
              set -x
              sleep ${toString i}
              SNAPSHOT=$(${pkgs.btrfs-progs}/bin/btrfs subvolume list --sort=-gen -r -o ${subvolume} | \
                  ${pkgs.gawk}/bin/awk '{print $9; exit}')
              cd "/$SNAPSHOT"
            '';
            prune.keep = {
              within = "1d";
              daily = 7;
              weekly = 4;
              monthly = 3;
            };
            environment = {
              BORG_HOST_ID =
                let
                  h = config.networking;
                in
                "${h.hostName}.${h.domain}@${h.hostId}";
            } // lib.optionalAttrs (cfg.sshKeyPath != null) { BORG_RSH = ''ssh -i "${cfg.sshKeyPath}"''; };
          }
          // lib.optionalAttrs (attrs ? patterns) { inherit (attrs) patterns; }
          // lib.optionalAttrs (attrs ? prune) { inherit (attrs) prune; }
        )
      ) cfg.dirs
    );

    mj.base.unitstatus.units =
      let
        sanitized = map lib.strings.sanitizeDerivationName (lib.catAttrs "subvolume" cfg.dirs);
      in
      lib.imap0 (i: name: "borgbackup-job-${name}-${toString i}") sanitized;
  };
}

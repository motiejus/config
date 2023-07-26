{
  config,
  lib,
  pkgs,
  ...
}: let
  mountLatest = mountpoint: zfs_name: ''
    set -euo pipefail
    ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest &>/dev/null || :
    mkdir -p ${mountpoint}/.snapshot-latest
    ${pkgs.util-linux}/bin/mount -t zfs $(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name ${zfs_name} | sort | tail -1) ${mountpoint}/.snapshot-latest
  '';

  umountLatest = mountpoint: ''
    exec ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest
  '';
in {
  options.mj.base.zfsborg = with lib.types; {
    enable = lib.mkEnableOption "backup zfs snapshots with borg";

    passwordPath = lib.mkOption {type = str;};
    sshKeyPath = lib.mkOption {
      type = nullOr path;
      default = null;
    };

    mountpoints = lib.mkOption {
      default = {};
      type = attrsOf (submodule (
        {...}: {
          options = {
            repo = lib.mkOption {type = str;};
            paths = lib.mkOption {type = listOf path;};
            patterns = lib.mkOption {
              type = listOf str;
              default = [];
            };
            backup_at = lib.mkOption {type = str;};
          };
        }
      ));
    };
  };

  config = lib.mkIf config.mj.base.zfsborg.enable {
    systemd.services."zfsborg-snapshot-dirs" = let
      mountpoints = lib.unique (lib.attrNames config.mj.base.zfsborg.mountpoints);
    in {
      description = "zfsborg prepare snapshot directories";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          builtins.map
          (d: "${pkgs.coreutils}/bin/mkdir -p ${d}/.snapshot-latest")
          mountpoints;
        RemainAfterExit = true;
      };
    };

    services.borgbackup.jobs = lib.mapAttrs' (mountpoint: attrs: let
      fs = builtins.getAttr mountpoint config.fileSystems;
    in
      assert fs.fsType == "zfs";
      assert lib.assertMsg
      config.mj.base.unitstatus.enable
      "config.mj.base.unitstatus.enable must be true"; {
        name = lib.strings.sanitizeDerivationName mountpoint;
        value =
          {
            doInit = true;
            repo = attrs.repo;
            encryption = {
              mode = "repokey-blake2";
              passCommand = "cat ${config.mj.base.zfsborg.passwordPath}";
            };
            paths = attrs.paths;
            extraArgs = "--remote-path=borg1";
            compression = "auto,lzma";
            startAt = attrs.backup_at;
            readWritePaths = let p = mountpoint + "/.snapshot-latest"; in [p];
            preHook = mountLatest mountpoint fs.device;
            postHook = umountLatest mountpoint;
            prune.keep = {
              within = "1d";
              daily = 7;
              weekly = 4;
              monthly = 3;
            };
          }
          // lib.optionalAttrs (attrs ? patterns) {
            patterns = attrs.patterns;
          }
          // lib.optionalAttrs (config.mj.base.zfsborg.sshKeyPath != null) {
            environment.BORG_RSH = ''ssh -i "${config.mj.base.zfsborg.sshKeyPath}"'';
          };
      })
    config.mj.base.zfsborg.mountpoints;

    mj.base.unitstatus.units = let
      mounts = config.mj.base.zfsborg.mountpoints;
      sanitized = map lib.strings.sanitizeDerivationName (lib.attrNames mounts);
    in
      map (n: "borgbackup-job-${n}") sanitized;
  };
}

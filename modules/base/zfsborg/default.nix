{
  config,
  lib,
  pkgs,
  myData,
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
  options.mj.base.zfsborg = {
    enable = lib.mkEnableOption "backup zfs snapshots with borg";

    repo = with lib.types; lib.mkOption {type = str;};
    passwdPath = with lib.types; lib.mkOption {type = str;};

    mountpoints = lib.mkOption {
      default = {};
      type = with lib.types;
        attrsOf (submodule (
          {...}: {
            options = {
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
      assert fs.fsType == "zfs"; {
        name = lib.strings.sanitizeDerivationName mountpoint;
        value =
          {
            doInit = true;
            repo = config.mj.base.zfsborg.repo;
            encryption = {
              mode = "repokey-blake2";
              passCommand = "cat ${config.mj.base.zfsborg.passwdPath}";
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
          };
      })
    config.mj.base.zfsborg.mountpoints;
  };
}

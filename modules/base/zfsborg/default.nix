{
  config,
  lib,
  pkgs,
  ...
}: let
  mkPreHook = mountpoint: zfs_name: ''
    set -x
    ${pkgs.util-linux}/bin/mount \
      -t zfs \
      -o ro \
      $(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name ${zfs_name} | sort | tail -1) \
      ${mountpoint}/.snapshot-latest
    cd ${mountpoint}/.snapshot-latest
  '';
in {
  options.mj.base.zfsborg = with lib.types; {
    enable = lib.mkEnableOption "backup zfs snapshots with borg";

    passwordPath = lib.mkOption {type = str;};
    sshKeyPath = lib.mkOption {
      type = nullOr path;
      default = null;
    };

    dirs = lib.mkOption {
      default = {};
      type = listOf (submodule (
        {...}: {
          options = {
            mountpoint = lib.mkOption {type = path;};
            repo = lib.mkOption {type = str;};
            paths = lib.mkOption {type = listOf str;};
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

  config = with config.mj.base.zfsborg;
    lib.mkIf enable {
      systemd.services =
        lib.listToAttrs (lib.imap0 (
            i: attr:
              lib.nameValuePair "borgbackup-job-${lib.strings.sanitizeDerivationName attr.mountpoint}-${toString i}" {
                serviceConfig.TemporaryFileSystem = "${attr.mountpoint}/.snapshot-latest";
              }
          )
          dirs)
        // {
          "zfsborg-snapshot-dirs" = {
            description = "zfsborg prepare snapshot directories";
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = let
                mountpoints = lib.unique (lib.catAttrs "mountpoint" dirs);
              in
                builtins.map
                (d: "${pkgs.coreutils}/bin/mkdir -p ${d}/.snapshot-latest")
                mountpoints;
              RemainAfterExit = true;
            };
          };
        };

      services.borgbackup.jobs = builtins.listToAttrs (
        lib.imap0 (
          i: attrs: let
            mountpoint = builtins.getAttr "mountpoint" attrs;
            fs = builtins.getAttr mountpoint config.fileSystems;
          in
            assert fs.fsType == "zfs";
            assert lib.assertMsg
            config.mj.base.unitstatus.enable
            "config.mj.base.unitstatus.enable must be true";
              lib.nameValuePair
              "${lib.strings.sanitizeDerivationName mountpoint}-${toString i}"
              ({
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
                  preHook = mkPreHook mountpoint fs.device;
                  prune.keep = {
                    within = "1d";
                    daily = 7;
                    weekly = 4;
                    monthly = 3;
                  };
                  environment =
                    {
                      BORG_HOST_ID = let
                        h = config.networking;
                      in "${h.hostName}.${h.domain}@${h.hostId}";
                    }
                    // lib.optionalAttrs (sshKeyPath != null) {
                      BORG_RSH = ''ssh -i "${config.mj.base.zfsborg.sshKeyPath}"'';
                    };
                }
                // lib.optionalAttrs (attrs ? patterns) {
                  patterns = attrs.patterns;
                })
        )
        dirs
      );

      mj.base.unitstatus.units = let
        sanitized = map lib.strings.sanitizeDerivationName (lib.catAttrs "mountpoint" dirs);
      in
        lib.imap0 (i: name: "borgbackup-job-${name}-${toString i}") sanitized;
    };
}

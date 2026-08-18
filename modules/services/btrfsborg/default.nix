{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.mj.services.btrfsborg;

  # A job's name becomes its archive prefix, so it has to be stable: two callers
  # need the same name, and a list index changes when a job is added.
  jobName = attrs: lib.strings.sanitizeDerivationName attrs.repo;

  # Every option a dir declares must appear here, and be read below.
  dirOptionsRead = [
    "backup_at" # startAt
    "compression"
    "paths"
    "patterns"
    "prune"
    "repo"
    "subvolume" # the snapshot the preHook cds into
  ];
in
{
  options.mj.services.btrfsborg = with lib.types; {
    enable = lib.mkEnableOption "backup btrfs snapshots with borg";

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
          # Include as well as exclude, first match winning; a job with no paths
          # names its roots here with "R" lines. See borg help patterns.
          patterns = lib.mkOption {
            type = listOf str;
            default = [ ];
          };
          prune = lib.mkOption {
            type = anything;
            default.keep = {
              within = "4w";
              # Without a floor, a repo whose backups stopped keeps nothing at
              # all four weeks later; measured on a real repo.
              last = 3;
            };
          };
          backup_at = lib.mkOption { type = str; };
          compression = lib.mkOption {
            type = str;
            default = "auto,zstd,10";
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    # listToAttrs keeps the last of a duplicate name, so two dirs whose repos
    # sanitise to one name would silently leave a host with one fewer backup.
    assertions = [
      {
        assertion = lib.length (lib.unique (map jobName cfg.dirs)) == lib.length cfg.dirs;
        message = "btrfsborg: two dirs share a job name; repos must differ by more than punctuation";
      }
    ];

    systemd.services = lib.listToAttrs (
      map (
        attrs:
        let
          svcName = "borgbackup-job-${jobName attrs}";
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
        # A dir option missing from dirOptionsRead is one nothing forwards.
        assert lib.assertMsg (lib.subtractLists dirOptionsRead (builtins.attrNames attrs) == [ ])
          "btrfsborg: dir options not listed as read: ${toString (lib.subtractLists dirOptionsRead (builtins.attrNames attrs))}";
        lib.nameValuePair (jobName attrs) {
          inherit (attrs)
            repo
            paths
            patterns
            compression
            ;

          # A failed create leaves "<name>.failed", which matches the prefix glob
          # and is newer than every real archive: four weeks of failures followed
          # by one success would prune the history away. Select by the date shape
          # instead, which .failed names do not have. The prefix has to go rather
          # than narrow, because borg takes only one -a.
          prune = attrs.prune // {
            prefix = null;
          };
          extraPruneArgs = "--glob-archives ${lib.escapeShellArg "${config.networking.hostName}-${jobName attrs}-????-??-??T??:??:??"}";

          doInit = true;
          encryption = {
            mode = "repokey-blake2";
            passCommand = "cat ${cfg.passwordPath}";
          };
          extraArgs = "--remote-path=borg1";
          extraCreateArgs = "--chunker-params buzhash,10,23,16,4095";
          startAt = attrs.backup_at;
          preHook = ''
            set -x
            sleep ${toString i}
            SNAPSHOT=$(${pkgs.btrfs-progs}/bin/btrfs subvolume list --sort=-gen -r -o ${subvolume} | \
                ${pkgs.gawk}/bin/awk '{print $9; exit}')
            # Without this, cd "/" succeeds and the live filesystem is archived.
            [ -n "$SNAPSHOT" ]
            cd "/$SNAPSHOT"
            # An empty path archives cleanly, and the prune then makes that
            # emptiness permanent four weeks later.
            for p in ${lib.escapeShellArgs attrs.paths}; do
              [ -n "$(${pkgs.findutils}/bin/find "$p" -mindepth 1 -print -quit)" ]
            done
          '';
          environment = {
            BORG_RELOCATED_REPO_ACCESS_IS_OK = "yes";
            BORG_HOST_ID =
              let
                h = config.networking;
              in
              "${h.hostName}.${h.domain}@${h.hostId}";
          }
          // lib.optionalAttrs (cfg.sshKeyPath != null) { BORG_RSH = ''ssh -i "${cfg.sshKeyPath}"''; };
        }
      ) cfg.dirs
    );

    mj.base.unitstatus.units = map (attrs: "borgbackup-job-${jobName attrs}") cfg.dirs;
  };
}

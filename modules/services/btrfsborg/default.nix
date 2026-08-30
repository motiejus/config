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

  # Borg identifies a lock's owner by this, so the check has to claim the same
  # identity as the backup or it cannot tell its own stale lock from a stranger's.
  borgEnv = config': {
    BORG_RELOCATED_REPO_ACCESS_IS_OK = "yes";
    BORG_HOST_ID = "${config'.hostName}.${config'.domain}@${config'.hostId}";
  };

  # Every option a dir declares must appear here, and be read below.
  dirOptionsRead = [
    "backup_at" # startAt
    "chunkerParams"
    "compression"
    "exclude"
    "passwordPath"
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
    # Segment CRCs only, which borg runs on the repository's own host. Weekly is
    # plenty for catching bit rot; anything that needs the key is a manual job.
    checkAt = lib.mkOption {
      type = nullOr str;
      default = null;
    };
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
          # Repositories can be on different passphrases, and are while one is
          # being moved: "borg key change-passphrase" re-encrypts the stored key
          # rather than the data, so a repository moves in seconds, but it moves
          # one at a time. Null takes the host's.
          passwordPath = lib.mkOption {
            type = nullOr str;
            default = null;
          };
          paths = lib.mkOption { type = listOf str; };
          # Subtrees below a path that are not worth storing. Borg does not
          # descend into an excluded directory. See borg help patterns.
          exclude = lib.mkOption {
            type = listOf str;
            default = [ ];
          };
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
          # "auto" tries lz4 first and only reaches for zstd if that shrank the
          # chunk below 97% (compress.pyx), so already-compressed data costs
          # little whatever the level. Level 10 over level 3 was measured on this
          # host's own data: 0.93% smaller on the databases for 69% more CPU,
          # 0.26% on the photo and mail set for 56% more. It earns its CPU only
          # on prometheus blocks, at 3.6%, so that job asks for it by name.
          compression = lib.mkOption {
            type = str;
            default = "auto,zstd,3";
          };
          # Small chunks buy deduplication on files rewritten in place and cost
          # index entries on files only ever appended or replaced whole, so this
          # follows how a job's data changes rather than what it is. Measured per
          # night, per data class, on six real consecutive nights:
          #
          #                       state(db)   blobs   metrics   annex2
          #   fixed,4096            0.085       -        -        -
          #   buzhash,10,23,16      0.356     0.015    0.301    (best)
          #   buzhash,12,23,18      0.726     0.024    0.276      -
          #   buzhash,19,23,21      1.314     0.041    0.249      -
          #   buzhash,19,23,22        -       0.048    0.245    +5.1%
          #
          # Rewritten databases want the page-aligned fixed chunker and pay for
          # it in index size (1.8M chunks, 843 MB RSS for 7.7 GB). Immutable
          # blocks want the largest chunker, which is cheaper on every axis at
          # once because there is no deduplication to lose. Nothing can re-chunk
          # an existing repository: the files cache hands back stored chunk ids
          # for unchanged files, so a change here only ever reaches new data.
          chunkerParams = lib.mkOption {
            type = str;
            default = "buzhash,10,23,16,4095";
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
        lib.nameValuePair svcName {
          serviceConfig = {
            RuntimeDirectory = svcName;
            # The preHook bind-mounts the snapshot here; keep that mount inside
            # the unit rather than leaking it into the host namespace.
            PrivateMounts = true;
          };
        }
      ) cfg.dirs
      ++ lib.optionals (cfg.checkAt != null) (
        map (
          attrs:
          lib.nameValuePair "borgbackup-check-${jobName attrs}" {
            description = "Borg repository check for ${attrs.repo}";
            path = [
              pkgs.borgbackup
              pkgs.openssh
            ];
            # --repository-only reads every segment and verifies its magic and
            # CRCs, which is what finds bit rot. It needs no key, so borg runs it
            # on the repository's own host and nothing but the verdict crosses
            # the network. Checking the archives needs the key and therefore runs
            # here, pulling metadata for every archive; that one is worth doing by
            # hand, on one repository at a time.
            script = "borg check --remote-path=borg1 --repository-only";
            startAt = cfg.checkAt;
            environment =
              borgEnv config.networking
              // {
                BORG_REPO = attrs.repo;
              }
              // lib.optionalAttrs (cfg.sshKeyPath != null) { BORG_RSH = ''ssh -i "${cfg.sshKeyPath}"''; };
            serviceConfig = {
              Type = "oneshot";
              CPUSchedulingPolicy = "idle";
              IOSchedulingClass = "idle";
              ProtectSystem = "strict";
              # Borg's self-test creates a temporary file. ProtectSystem=strict
              # makes the host's /tmp read-only, so provide a private writable one.
              PrivateTmp = true;
              # Borg records where it last saw this repository under ~/.config/borg.
              ReadWritePaths = [
                "/root/.config/borg"
                "/root/.cache/borg"
              ];
            };
          }
        ) cfg.dirs
      )
    );

    # A check holds the repository exclusively, so it must not land on a backup.
    # Spreading them also keeps eight of them off one destination at once.
    systemd.timers = lib.mkIf (cfg.checkAt != null) (
      lib.listToAttrs (
        map (
          attrs:
          lib.nameValuePair "borgbackup-check-${jobName attrs}" {
            timerConfig.RandomizedDelaySec = "3h";
          }
        ) cfg.dirs
      )
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
            exclude
            compression
            ;

          # A failed create leaves "<name>.failed", which matches the prefix glob
          # and is newer than every real archive: four weeks of failures followed
          # by one success would prune the history away. Select by the date shape
          # instead, which .failed names do not have. The prefix has to go rather
          # than narrow, because borg takes only one -a.
          #
          # One job writes one repo, so the date shape alone is enough. Naming the
          # job in the glob would orphan every archive written under a previous
          # name, which is how this repo accumulated 587 unprunable archives.
          prune = attrs.prune // {
            prefix = null;
          };
          extraPruneArgs = "--glob-archives ${lib.escapeShellArg "*-????-??-??T??:??:??"}";

          doInit = true;
          encryption = {
            mode = "repokey-blake2";
            passCommand = "cat ${if attrs.passwordPath != null then attrs.passwordPath else cfg.passwordPath}";
          };
          extraArgs = "--remote-path=borg1";
          extraCreateArgs = "--chunker-params ${attrs.chunkerParams}";
          startAt = attrs.backup_at;
          preHook = ''
            set -x
            sleep ${toString i}
            SNAPSHOT=$(${pkgs.btrfs-progs}/bin/btrfs subvolume list --sort=-gen -r -o ${subvolume} | \
                ${pkgs.gawk}/bin/awk '{print $9; exit}')
            # Without this, cd "/" succeeds and the live filesystem is archived.
            [ -n "$SNAPSHOT" ]
            # Borg hashes the absolute path of every file into its files cache, and
            # a snapshot directory is named after the hour it was taken. Reading the
            # snapshot through its own path therefore misses the cache on every file
            # on every run, and re-reads the whole subvolume nightly. The bind mount
            # gives each job one path that does not move.
            mkdir -p "$RUNTIME_DIRECTORY/snapshot"
            ${pkgs.util-linux}/bin/mount --bind "/$SNAPSHOT" "$RUNTIME_DIRECTORY/snapshot"
            cd "$RUNTIME_DIRECTORY/snapshot"
            # An empty path archives cleanly, and the prune then makes that
            # emptiness permanent four weeks later.
            for p in ${lib.escapeShellArgs attrs.paths}; do
              [ -n "$(${pkgs.findutils}/bin/find "$p" -mindepth 1 -print -quit)" ]
            done
          '';
          postHook = ''
            # umount refuses while this shell still sits inside the mount.
            cd /
            ${pkgs.util-linux}/bin/umount "$RUNTIME_DIRECTORY/snapshot" || :
          '';
          environment =
            borgEnv config.networking
            // lib.optionalAttrs (cfg.sshKeyPath != null) { BORG_RSH = ''ssh -i "${cfg.sshKeyPath}"''; };
        }
      ) cfg.dirs
    );

    mj.base.unitstatus.units =
      map (attrs: "borgbackup-job-${jobName attrs}") cfg.dirs
      ++ lib.optionals (cfg.checkAt != null) (map (attrs: "borgbackup-check-${jobName attrs}") cfg.dirs);
  };
}

# One-time setup, from the repo root on a machine with a browser:
#
# 1. Google Cloud console (console.cloud.google.com):
#    - create a project; enable "People API" and "Google Drive API"
#      (APIs & Services -> Library);
#    - OAuth consent screen: External, publishing status "In production". In
#      "Testing" refresh tokens expire after 7 days; in production any Google
#      account may authorize (no test-user list), behind an "unverified app"
#      warning to click through;
#    - Credentials -> Create OAuth client ID -> Desktop app; download its JSON
#      and note the client ID and secret ($ID, $SECRET below).
#
# 2. Create the backup@jakstys.lt Google account (accounts.google.com ->
#    Create account -> "Use my current email address instead"), and share the
#    documents and folders to back up with it as Viewer. Files whose owner
#    disabled download for viewers fail every night: share those as Editor, or
#    don't share them. Files with the same name in one Drive folder (or at the
#    shared-with-me root) back up only one of them; rename to keep both.
#
# 3. rclone token for backup@jakstys.lt: open the printed URL in a private
#    window and log in as backup@jakstys.lt. Prints one line of JSON:
#      nix shell --inputs-from . nixpkgs#rclone nixpkgs#jq
#      blob=$(jq -nc --arg id "$ID" --arg s "$SECRET" \
#        '{client_id:$id,client_secret:$s,scope:"drive.readonly"}' \
#        | base64 -w0 | tr -d '=')
#      rclone authorize --auth-no-open-browser drive "$blob" \
#        | sed -n '/^Paste/{n;p;}' | jq -rR '@base64d | fromjson | .token'
#
# 4. Contacts token for your own account (log in as yourself):
#      nix run .#google-contacts -- auth -client ~/Downloads/client_secret_*.json -out /tmp/gc.json
#
# 5. agenix -e secrets/fwminex/google-backup.env.age, JSON in single quotes:
#      RCLONE_CONFIG_GDRIVE_CLIENT_ID=$ID
#      RCLONE_CONFIG_GDRIVE_CLIENT_SECRET=$SECRET
#      RCLONE_CONFIG_GDRIVE_TOKEN='<line from step 3>'
#      GOOGLE_CONTACTS_TOKEN='<contents of /tmp/gc.json>'
#    then rm /tmp/gc.json. Add *.partial to M-R/.stignore to hide
#    rclone's temp files from Syncthing.
#
# 6. After deploying: systemctl start google-backup; journalctl -u google-backup
#
# Both mirrors keep files changed or added on disk: one that differs from the
# manifest of what the last run wrote (or is not in it) is renamed to
# <stem>-kept-<time><ext> before it is overwritten or deleted; for Drive, rclone
# --suffix does it for what a peer changes during the run. Residual windows:
# the first run keeps nothing; an edit landing after rclone wrote a file but
# before the manifest is built is blessed; a SIGKILL leaves a stale manifest,
# so the next run may keep files the mirror wrote; a Drive file with a Syncthing
# conflict or temp name is not backed up.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.google-backup;
  runDir = "/run/google-backup";
  stateDir = "/var/lib/google-backup";
  # sha256 per file each mirror wrote or confirmed in its last run (see the header).
  contactsManifest = "${stateDir}/contacts.sha256";
  driveManifest = "${stateDir}/drive.sha256";
  # Scratch files of one Drive run: hashes before the sync (.pre), rclone's
  # report of what it did (.combined), hashes after it (.post) and of the files
  # it kept (.kept).
  driveTmp = "${runDir}/drive";
  # Kept copies: <stem>-kept-YYYY-MM-DD-HHMMSS<ext>. Drive files named like
  # them, like Syncthing's or rclone's temp files, are not backed up.
  keptGlob = "*-kept-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*";
  # What the sync and the hashing of driveDir both skip.
  driveExcludes = "--exclude '${keptGlob}' --exclude '.syncthing.*' --exclude '*.partial'";
  timeoutSec = 3600;
  dirs = [
    cfg.contactsDir
    cfg.driveDir
  ];

  backupScript = pkgs.writeShellApplication {
    name = "google-backup";
    runtimeInputs = with pkgs; [
      coreutils
      google-contacts
      jq
      rclone
    ];
    text = ''
      failed=0
      pid=
      stop=
      now=
      suffix=()
      declare -A was pre post reported failedn

      # KillMode=mixed signals only this script, so it forwards TERM and INT to
      # the command it runs (see run) and finishes the manifest work itself.
      trap 'stop=1; [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null' TERM INT

      # Runs "$@" in the background, so the trap can pass a signal on to it, and
      # returns its status.
      run() {
        local rc=0
        [ -z "$stop" ] || return 143
        "$@" &
        pid=$!
        wait "$pid" || rc=$?
        while kill -0 "$pid" 2>/dev/null; do wait "$pid" || rc=$?; done
        pid=
        return "$rc"
      }

      run google-contacts sync -manifest ${contactsManifest} -out ${cfg.contactsDir} || failed=1

      # "sha256  name" lines (names as rclone spells them, as in its sync
      # report) for the files in driveDir that the mirror owns; a hash failure
      # still lists the rest.
      drive_hashes() {
        rclone hashsum -q sha256 ${cfg.driveDir} "$@" ||
          echo "drive: some files could not be hashed" >&2
      }

      # Fills the associative array named $1 (name to hash) from the lines of $2.
      load_hashes() {
        local -n _hashes=$1
        local line
        while IFS= read -r line; do
          [[ $line =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || { echo "drive: malformed $2" >&2; return 1; }
          _hashes["''${BASH_REMATCH[2]}"]=''${BASH_REMATCH[1]}
        done < "$2"
        # An unterminated last line is a truncated file.
        [ -z "$line" ] || { echo "drive: malformed $2" >&2; return 1; }
      }

      # Hashes driveDir; with a manifest, moves each file that differs from it
      # (or is not in it) to <stem>-kept-<time><ext> and has the sync keep what
      # it overwrites or deletes in the same way. The extension is split at the
      # last dot here, while rclone also keeps known multi-part ones (.tar.gz).
      drive_keep() {
        local name stem ext
        drive_hashes ${driveExcludes} > ${driveTmp}.pre || return 1
        load_hashes pre ${driveTmp}.pre || return 1
        [ -e ${driveManifest} ] || return 0
        load_hashes was ${driveManifest} || return 1
        suffix=(--suffix "-kept-$now" --suffix-keep-extension)
        for name in "''${!pre[@]}"; do
          [ "''${was[$name]-}" != "''${pre[$name]}" ] || continue
          stem=$name ext=
          # A Drive "/" is "／" in rclone names; an extension never spans it.
          if [[ ''${name##*/} == ?*.* && ''${name##*.} != *／* ]]; then stem=''${name%.*} ext=.''${name##*.}; fi
          rclone moveto -q "${cfg.driveDir}/$name" "${cfg.driveDir}/$stem-kept-$now$ext" || return 1
          unset "pre[$name]"
        done
        for name in "''${!pre[@]}"; do
          echo "''${pre[$name]}  $name" || return 1
        done > ${driveTmp}.pre
      }

      # Sorts out this run's kept files: one that is the backup's own previous
      # version (same hash as the old manifest) is deleted if the sync replaced or
      # deleted the file, else (the download failed or was cut short) moved back.
      # The rest are counted.
      drive_kept() {
        local -A kept
        local name orig count=0
        drive_hashes --filter '- .syncthing.*' --filter "+ *-kept-$now*" --filter '- *' > ${driveTmp}.kept || return 1
        load_hashes kept ${driveTmp}.kept || return 1
        for name in "''${!kept[@]}"; do
          orig=''${name/-kept-$now/}
          if [ "''${was[$orig]-}" != "''${kept[$name]}" ]; then
            count=$((count + 1))
          elif [ -n "''${post[$orig]-}" ] || [ "''${reported[$orig]-}" = - ]; then
            rclone deletefile -q "${cfg.driveDir}/$name" || return 1
          else
            # A peer may have recreated the name meanwhile: then this stays kept.
            rclone moveto -q --ignore-existing "${cfg.driveDir}/$name" "${cfg.driveDir}/$orig" || return 1
            if [ -n "$(rclone lsf -q "${cfg.driveDir}/$name" 2> /dev/null)" ]; then
              count=$((count + 1))
            else
              post[$orig]=''${kept[$name]}
            fi
          fi
        done
        if [ "$count" -eq 0 ]; then
          echo "drive: 0 files changed on disk since the last run"
        else
          echo "drive: $count files changed on disk since the last run, kept as *-kept-$now*"
        fi
      }

      # Writes the manifest: each file that rclone wrote (+ or * in its report,
      # without a failure) or that is as it was before the sync, with its hash
      # now. Any other file, such as one a Syncthing peer changed meanwhile, is
      # left out and so kept next run. A manifest is never installed incomplete.
      drive_manifest() {
        local name
        for name in "''${!post[@]}"; do
          if { [[ ''${reported[$name]-} == [+*] ]] && [ -z "''${failedn[$name]-}" ]; } || [ "''${pre[$name]-}" = "''${post[$name]}" ]; then
            echo "''${post[$name]}  $name" || return 1
          fi
        done > ${driveManifest}.tmp || return 1
        mv ${driveManifest}.tmp ${driveManifest}
      }

      # After the sync, whatever its status: sorts out the kept files, logs what
      # happened (not what rclone intended) and records the manifest.
      drive_finish() {
        local line name new=0 updated=0 removed=0 same=0 errors=0 rc=0
        while IFS= read -r line; do
          name=''${line:2}
          if [ "''${line:0:1}" = '!' ]; then
            failedn[$name]=1
            errors=$((errors + 1))
          else
            reported[$name]=''${line:0:1}
          fi
        done < ${driveTmp}.combined
        drive_hashes ${driveExcludes} > ${driveTmp}.post || return 1
        load_hashes pre ${driveTmp}.pre || return 1
        load_hashes post ${driveTmp}.post || return 1
        if [ -z "''${suffix[*]}" ]; then
          echo "drive: no previous run, nothing kept"
        else
          drive_kept || rc=1
        fi
        for name in "''${!reported[@]}"; do
          case ''${reported[$name]} in
            [+*]) [ "''${pre[$name]-}" != "''${post[$name]-}" ] &&
              { [ "''${reported[$name]}" = + ] && new=$((new + 1)) || updated=$((updated + 1)); } ;;
            -) [ -z "''${post[$name]-}" ] && removed=$((removed + 1)) ;;
            =) same=$((same + 1)) ;;
          esac
        done
        echo "drive: done: $new new, $updated updated, $removed removed, $same unchanged, $errors failed"
        drive_manifest || rc=1
        [ "$rc" -eq 0 ] || echo "drive: cannot finish ${driveManifest}" >&2
        return "$rc"
      }

      drive() {
        local size out count rc=0
        [ -z "$stop" ] || return 1
        size=$(rclone size -q --json gdrive:) || return 1
        out=$(jq -er 'if (.count | type) == "number" then (.count | tostring), "drive: logged in; \(.count) files shared with the backup account, \(.bytes) bytes + \(.sizeless) of unknown size" else error("no count") end' <<< "$size") || return 1
        count=''${out%%$'\n'*}
        echo "''${out#*$'\n'}"
        # rclone sync would mirror an empty listing by deleting all of driveDir.
        if [ "$count" -eq 0 ] && [ -n "$(ls -A ${cfg.driveDir})" ]; then
          echo "drive: nothing is shared with the backup account; keeping ${cfg.driveDir}" >&2
          return 1
        fi
        now=$(date +%F-%H%M%S)
        drive_keep || return 1
        : > ${driveTmp}.combined
        # One attempt: --combined holds only the last one, so after a retry the
        # files fetched earlier would look unconfirmed and be kept every night.
        run rclone sync -q --retries 1 "''${suffix[@]}" --combined ${driveTmp}.combined ${driveExcludes} \
          gdrive: ${cfg.driveDir} || rc=$?
        drive_finish || [ "$rc" -ne 0 ] || rc=1
        return "$rc"
      }
      drive || failed=1
      [ -z "$stop" ] || failed=1

      exit "$failed"
    '';
  };
in
{
  options.mj.services.google-backup = with lib.types; {
    enable = lib.mkEnableOption "nightly backup of Google contacts and Drive documents";
    user = lib.mkOption {
      type = str;
      description = "User that owns contactsDir and driveDir.";
    };
    contactsDir = lib.mkOption {
      type = path;
      description = "Where contacts go, one vCard each.";
    };
    driveDir = lib.mkOption {
      type = path;
      description = "Where Drive files shared with the backup account go.";
    };
    secretsEnv = lib.mkOption {
      type = path;
      description = "EnvironmentFile with RCLONE_CONFIG_GDRIVE_{CLIENT_ID,CLIENT_SECRET,TOKEN} and GOOGLE_CONTACTS_TOKEN.";
    };
    onCalendar = lib.mkOption {
      type = str;
      default = "*-*-* 00:15:00 UTC";
      description = "When to run; the default finishes before fwminex's 01:00 backups.";
    };
  };

  config = lib.mkIf cfg.enable {
    mj.base.unitstatus.units = [ "google-backup" ];

    systemd = {
      tmpfiles.rules = map (d: "d ${d} 0700 ${cfg.user} ${config.users.users.${cfg.user}.group} -") dirs;

      services.google-backup = {
        description = "Back up Google contacts and Drive documents";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = {
          # Lets rclone save the token it refreshes.
          RCLONE_CONFIG = "${runDir}/rclone.conf";
          RCLONE_CONFIG_GDRIVE_TYPE = "drive";
          RCLONE_CONFIG_GDRIVE_SCOPE = "drive.readonly";
          RCLONE_CONFIG_GDRIVE_SHARED_WITH_ME = "true";
          # A dangling shortcut would 404 every night and, via ErrorNotDeleting, block all deletions.
          RCLONE_CONFIG_GDRIVE_SKIP_DANGLING_SHORTCUTS = "true";
          RCLONE_CONFIG_GDRIVE_EXPORT_FORMATS = "docx,xlsx,pptx,svg";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe backupScript;
          TimeoutStartSec = timeoutSec;
          # After SIGTERM only the script is signalled; it stops rclone, then
          # hashes all of driveDir for the manifest.
          KillMode = "mixed";
          TimeoutStopSec = 600;
          EnvironmentFile = [ cfg.secretsEnv ];
          User = cfg.user;
          RuntimeDirectory = "google-backup";
          StateDirectory = "google-backup";
          UMask = "0077";

          ProtectSystem = "strict";
          ProtectHome = "tmpfs";
          BindPaths = dirs;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          NoNewPrivileges = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictSUIDSGID = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
          SystemCallArchitectures = "native";
          MemoryDenyWriteExecute = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
        };
      };

      timers.google-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.onCalendar;
          Persistent = true;
        };
      };
    };
  };
}

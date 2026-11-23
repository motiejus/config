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
#    don't share them.
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
#      nix run .#google-backup -- auth -client ~/Downloads/client_secret_*.json -out /tmp/gc.json
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
# Both mirrors keep a file that differs from what the last run wrote as
# <stem>-kept-<time><ext> (-kept-<time>-2<ext> or -kept-<time>-sync<ext> for
# a later copy in one run) before replacing it, and one whose source Google no
# longer has (deleted, trashed, unshared or moved out of a shared folder: Google
# cannot tell them apart) as <stem>-deleted-<date><ext>, or -deleted-<time> if
# that name is taken. Copies are never touched again; a file restored in
# Google comes back beside its copy. Drive files named like copies are not
# backed up. Drive renames and moves are followed by file ID without a
# download; Drive files sharing a name are backed up as <stem>~N<ext>.
# A missing manifest is an empty one: a file that matches Google (a Drive
# file by sha256 and ModTime, or by ModTime alone if Drive lists it without a
# sha256, as Google documents; a vCard byte for byte) is recorded, any other
# is kept as -kept- before it is replaced or removed.
# Limits: with no manifest, a local edit of a Drive file without a sha256
# that kept its ModTime is taken for Google's, and Drive files sharing a name
# whose numbers no longer follow their IDs are each kept once; the first run
# on a manifest from before IDs were recorded for every file keeps a renamed
# file, or one whose name a new file now shares, as -deleted- once; a run
# killed with SIGKILL may leave a deleted file as -kept-; and local Drive
# names with ‛ (U+201B) before an ordinary character fail the sync.
#
# /var/lib/google-backup/history.tsv gets one line per action and is never
# read back; unlike the journal, it holds names and IDs. Fields, tab-separated:
#   <time>  <drive|contacts>  <action>  <ID|->  <sha256|->  <name>  [<new name>]
# with actions new, updated, renamed, removed, deleted, kept and failed, and
# names and IDs Go-quoted (one record per line). Drive names are rclone's
# spelling of the name (a newline in a Drive name is ␊); a file added on disk
# whose name is not UTF-8 gets a lossy name, which its sha256 ties to the
# file. Each part ends with
#   <time>  <part>  run  <ok|failed|stopped>  -  <key=value totals>
# where stopped means a signal; totals count the actions so far. renamed
# overlaps the other totals: a plain rename is 1 renamed and 1 unchanged.
# A history that cannot be written fails the run but not the backup.
# After every run, whatever its outcome, history.tsv is copied over
# historyCopy (if set); edits made to the copy are discarded.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.google-backup;
  dirs = [
    cfg.contactsDir
    cfg.driveDir
  ];
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
    historyCopy = lib.mkOption {
      type = nullOr path;
      default = null;
      description = "Where to copy history.tsv after every run, replacing what is there; outside contactsDir and driveDir.";
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
        path = [ pkgs.rclone ];
        environment = {
          # Lets rclone save the token it refreshes.
          RCLONE_CONFIG = "/run/google-backup/rclone.conf";
          RCLONE_CONFIG_GDRIVE_TYPE = "drive";
          RCLONE_CONFIG_GDRIVE_SCOPE = "drive.readonly";
          RCLONE_CONFIG_GDRIVE_SHARED_WITH_ME = "true";
          # A dangling shortcut would 404 every night and, via ErrorNotDeleting, block all deletions.
          RCLONE_CONFIG_GDRIVE_SKIP_DANGLING_SHORTCUTS = "true";
          RCLONE_CONFIG_GDRIVE_EXPORT_FORMATS = "docx,xlsx,pptx,svg";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.google-backup} run -state /var/lib/google-backup -contacts ${cfg.contactsDir} -drive ${cfg.driveDir}";
          TimeoutStartSec = 3600;
          # After SIGTERM only google-backup is signalled; it stops rclone,
          # then hashes all of driveDir for the manifest.
          KillMode = "mixed";
          TimeoutStopSec = 600;
          # Syncthing ignores .syncthing.*.tmp but never writes this one itself.
          ExecStopPost = lib.optional (cfg.historyCopy != null) (
            pkgs.writeShellScript "google-backup-history-copy" ''
              set -e
              [ -e "$STATE_DIRECTORY/history.tsv" ] || exit 0
              tmp=${lib.escapeShellArg "${dirOf cfg.historyCopy}/.syncthing.${baseNameOf cfg.historyCopy}.google-backup.tmp"}
              cp "$STATE_DIRECTORY/history.tsv" "$tmp"
              mv -T "$tmp" ${lib.escapeShellArg cfg.historyCopy}
            ''
          );
          EnvironmentFile = [ cfg.secretsEnv ];
          User = cfg.user;
          RuntimeDirectory = "google-backup";
          StateDirectory = "google-backup";
          UMask = "0077";

          ProtectSystem = "strict";
          ProtectHome = "tmpfs";
          BindPaths = dirs ++ lib.optional (cfg.historyCopy != null) (dirOf cfg.historyCopy);
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

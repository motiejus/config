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
#    then rm /tmp/gc.json. Add *.partial to M-Documents/.stignore to hide
#    rclone's temp files from Syncthing.
#
# 6. After deploying: systemctl start google-backup; journalctl -u google-backup
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.mj.services.google-backup;
  runDir = "/run/google-backup";

  backupScript = pkgs.writeShellApplication {
    name = "google-backup";
    runtimeInputs = with pkgs; [
      coreutils
      google-contacts
      rclone
    ];
    text = ''
      failed=0
      google-contacts sync -out contacts || failed=1

      # rclone sync would mirror an empty listing by deleting all of docs/.
      if ! listing=$(rclone lsf --max-depth 1 gdrive:); then
        echo "rclone lsf failed; keeping docs/" >&2
        failed=1
      elif [ -z "$listing" ] && [ -n "$(ls -A docs 2> /dev/null)" ]; then
        echo "nothing is shared with the backup account; keeping docs/" >&2
        failed=1
      else
        rclone sync gdrive: docs || failed=1
      fi

      exit "$failed"
    '';
  };
in
{
  options.mj.services.google-backup = with lib.types; {
    enable = lib.mkEnableOption "nightly backup of Google contacts and Drive documents";
    user = lib.mkOption {
      type = str;
      description = "User that owns outputDir.";
    };
    outputDir = lib.mkOption {
      type = path;
      description = "Contacts go to contacts/, Drive files shared with the backup account to docs/.";
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
      tmpfiles.rules = [
        "d ${cfg.outputDir} 0700 ${cfg.user} ${config.users.users.${cfg.user}.group} -"
      ];

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
          TimeoutStartSec = "1h";
          EnvironmentFile = [ cfg.secretsEnv ];
          User = cfg.user;
          WorkingDirectory = cfg.outputDir;
          RuntimeDirectory = "google-backup";
          UMask = "0077";

          ProtectSystem = "strict";
          ProtectHome = "tmpfs";
          BindPaths = [ cfg.outputDir ];
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

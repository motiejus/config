{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.lt-shelters;
  readme = pkgs.writeText "lt-shelters-README.md" ''
    # Lithuanian public shelter data

    Full-country snapshots of Lithuania's official Priedanga (short-term
    protection) and KAS (collective protection structure) datasets. Files are
    kept as source JSON Lines without re-encoding.

    Sources:

    - Priedanga: https://data.gov.lt/datasets/2852/
    - KAS: https://data.gov.lt/datasets/2878/

    The snapshots are refreshed every seven days. Each successful refresh writes
    its UTC completion time to `refreshed-at.txt` and creates a commit even when
    the source bytes did not change. See LICENSE-DATA.md for reuse terms and
    attribution.
  '';
  dataLicense = pkgs.writeText "lt-shelters-LICENSE-DATA.md" ''
    # Data licence and attribution

    The source datasets are published under the Creative Commons Attribution
    4.0 International licence (CC BY 4.0):
    https://creativecommons.org/licenses/by/4.0/

    Attribution: Priešgaisrinės apsaugos ir gelbėjimo departamentas
    (PAGD), Valstybės duomenų agentūra, and Lietuvos atvirų duomenų
    portalas; source datasets “Priedangos” and “Kolektyvinės apsaugos
    statiniai”.

    Source catalogue records:

    - https://data.gov.lt/datasets/2852/
    - https://data.gov.lt/datasets/2878/

    These repository snapshots are automated, unmodified downloads. The Git
    history and repository metadata are not part of the source datasets.
  '';
  update = pkgs.writeShellApplication {
    name = "update-lt-shelters";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.diffutils
      pkgs.findutils
      pkgs.git
      pkgs.gnutar
      pkgs.gnused
      pkgs.jq
      pkgs.nix
      cfg.package
      pkgs.openssh
    ];
    text = ''
      shelters_repo="$STATE_DIRECTORY/repo"
      lt_maps_repo="$STATE_DIRECTORY/lt-maps"
      publish_dir=/var/www/dl/maps
      export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o IdentitiesOnly=yes -o SendEnv=GIT_DEFAULT_HASH"

      shelters_tree=
      pbf_tmp=
      md5_tmp=
      publish_tmp=
      manifest_tmp=
      cleanup() {
        for path in "$pbf_tmp" "$md5_tmp" "$publish_tmp" "$manifest_tmp"; do
          if [ -n "$path" ]; then
            rm -f -- "$path"
          fi
        done
        if [ -n "$shelters_tree" ]; then
          rm -rf -- "$shelters_tree"
        fi
      }
      trap cleanup EXIT

      mkdir -p "$publish_dir"
      find "$publish_dir" -maxdepth 1 -type f -name '.tmp-*' -delete

      if [ ! -d "$shelters_repo/.git" ]; then
        mkdir -p "$shelters_repo"
        git -C "$shelters_repo" init --object-format=sha256 --initial-branch=main
      fi
      test "$(git -C "$shelters_repo" rev-parse --show-object-format)" = sha256
      if git -C "$shelters_repo" remote get-url origin >/dev/null 2>&1; then
        git -C "$shelters_repo" remote set-url origin ${lib.escapeShellArg cfg.repo}
      else
        git -C "$shelters_repo" remote add origin ${lib.escapeShellArg cfg.repo}
      fi
      if git -C "$shelters_repo" fetch origin main; then
        git -C "$shelters_repo" reset --hard origin/main
      fi

      git -C "$shelters_repo" config user.name ${lib.escapeShellArg cfg.gitUserName}
      git -C "$shelters_repo" config user.email ${lib.escapeShellArg cfg.gitUserEmail}
      install -m 0644 ${readme} "$shelters_repo/README.md"
      install -m 0644 ${dataLicense} "$shelters_repo/LICENSE-DATA.md"
      fetch-priedangos "$shelters_repo/priedangos.jsonl"
      fetch-kas "$shelters_repo/kas.jsonl"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$shelters_repo/refreshed-at.txt"
      git -C "$shelters_repo" add README.md LICENSE-DATA.md priedangos.jsonl kas.jsonl refreshed-at.txt
      if ! git -C "$shelters_repo" diff --cached --quiet; then
        git -C "$shelters_repo" commit -m "Update PAGD shelter data"
      fi

      shelters_rev=$(git -C "$shelters_repo" rev-parse HEAD)
      shelters_tree=$(mktemp -d "$STATE_DIRECTORY/shelters-tree.XXXXXX")
      git -C "$shelters_repo" archive "$shelters_rev" | tar -x -C "$shelters_tree"
      shelters_hash=$(nix-hash --type sha256 --sri "$shelters_tree")
      rm -rf "$shelters_tree"
      shelters_tree=

      # Make the shelter revision reachable before lt-maps is allowed to
      # reference it.
      GIT_DEFAULT_HASH=sha256 git -C "$shelters_repo" push --set-upstream origin main

      pbf_tmp=$(mktemp "$STATE_DIRECTORY/lithuania.XXXXXX.osm.pbf")
      md5_tmp=$(mktemp "$STATE_DIRECTORY/lithuania.XXXXXX.md5")
      curl --fail --location --retry 4 --retry-all-errors --connect-timeout 30 --max-time 7200 --output "$pbf_tmp" https://download.geofabrik.de/europe/lithuania-latest.osm.pbf
      curl --fail --location --retry 4 --retry-all-errors --connect-timeout 30 --max-time 300 --output "$md5_tmp" https://download.geofabrik.de/europe/lithuania-latest.osm.pbf.md5
      upstream_md5=$(sed -n 's/^\([0-9a-fA-F]\{32\}\).*/\1/p' "$md5_tmp" | head -n 1)
      test -n "$upstream_md5"
      printf '%s  %s\n' "$upstream_md5" "$pbf_tmp" | md5sum --check --status -

      pbf_hash=$(nix-hash --flat --type sha256 --sri "$pbf_tmp")
      pbf_hex=$(sha256sum "$pbf_tmp" | cut -d' ' -f1)
      pbf_name="lithuania-$pbf_hex.osm.pbf"
      pbf_target="$publish_dir/$pbf_name"
      publish_tmp=$(mktemp "$publish_dir/.tmp-pbf.XXXXXX")
      install -m 0644 "$pbf_tmp" "$publish_tmp"
      if [ -e "$pbf_target" ]; then
        cmp "$publish_tmp" "$pbf_target"
        rm "$publish_tmp"
      else
        mv "$publish_tmp" "$pbf_target"
      fi
      rm "$pbf_tmp" "$md5_tmp"
      pbf_tmp=
      md5_tmp=
      publish_tmp=
      pbf_url="https://dl.jakstys.lt/maps/$pbf_name"

      # lt-maps is an ordinary SHA-1 repository. Override the service-wide
      # SHA-256 default used by the shelter repository when cloning it.
      if [ ! -d "$lt_maps_repo/.git" ]; then
        GIT_DEFAULT_HASH=sha1 git clone --branch main git@git.jakstys.lt:lt-maps.git "$lt_maps_repo"
      else
        GIT_DEFAULT_HASH=sha1 git -C "$lt_maps_repo" remote set-url origin git@git.jakstys.lt:lt-maps.git
        GIT_DEFAULT_HASH=sha1 git -C "$lt_maps_repo" fetch origin main
        GIT_DEFAULT_HASH=sha1 git -C "$lt_maps_repo" reset --hard origin/main
      fi
      test "$(git -C "$lt_maps_repo" rev-parse --show-object-format)" = sha1
      manifest="$lt_maps_repo/nix/data-sources.json"
      test -f "$manifest"
      manifest_tmp=$(mktemp "$STATE_DIRECTORY/data-sources.XXXXXX")
      jq --arg pbf_url "$pbf_url" --arg pbf_hash "$pbf_hash" --arg shelters_rev "$shelters_rev" --arg shelters_hash "$shelters_hash" '.osm.url = $pbf_url | .osm.hash = $pbf_hash | .shelters.url = "https://git.jakstys.lt/lt-shelters.git" | .shelters.rev = $shelters_rev | .shelters.hash = $shelters_hash' "$manifest" > "$manifest_tmp"
      chmod 0644 "$manifest_tmp"
      mv "$manifest_tmp" "$manifest"
      manifest_tmp=

      git -C "$lt_maps_repo" config user.name ${lib.escapeShellArg cfg.gitUserName}
      git -C "$lt_maps_repo" config user.email ${lib.escapeShellArg cfg.gitUserEmail}
      git -C "$lt_maps_repo" add -- nix/data-sources.json
      if ! git -C "$lt_maps_repo" diff --cached --quiet; then
        git -C "$lt_maps_repo" commit -m "Update Lithuania map data sources"
      fi
      GIT_DEFAULT_HASH=sha1 git -C "$lt_maps_repo" push --set-upstream origin main

      # Keep the PBF referenced by the just-pushed manifest. Superseded PBFs
      # remain downloadable for approximately three months.
      find "$publish_dir" -maxdepth 1 -type f -name 'lithuania-*.osm.pbf' ! -name "$pbf_name" -mtime +93 -delete
      trap - EXIT
    '';
  };
in
{
  options.mj.services.lt-shelters = {
    enable = lib.mkEnableOption "periodic Lithuanian shelter and map data snapshots";
    repo = lib.mkOption {
      type = lib.types.str;
      default = "git@git.jakstys.lt:lt-shelters.git";
      description = "Git repository receiving Priedanga and KAS snapshots";
    };
    gitUserName = lib.mkOption {
      type = lib.types.str;
      default = "Lithuanian shelter data bot";
    };
    gitUserEmail = lib.mkOption {
      type = lib.types.str;
      default = "lt-shelters@jakstys.lt";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lt-shelters;
      description = "Package containing fetch-priedangos and fetch-kas";
    };
    sshKeyPath = lib.mkOption {
      type = lib.types.path;
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = "SSH private key used to push shelters and lt-maps";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.lt-shelters = {
      description = "Lithuanian shelter data bot";
      isSystemUser = true;
      group = "lt-shelters";
      home = "/var/lib/lt-shelters";
      uid = myData.uidgid.lt-shelters;
    };
    users.groups.lt-shelters.gid = myData.uidgid.lt-shelters;
    systemd = {
      tmpfiles.rules = [
        "d /var/www/dl/maps 0755 lt-shelters lt-shelters -"
      ];

      services.lt-shelters = {
        description = "Snapshot Lithuanian shelters and update map data pins";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment.GIT_DEFAULT_HASH = "sha256";
        serviceConfig = {
          Type = "oneshot";
          User = "lt-shelters";
          Group = "lt-shelters";
          StateDirectory = "lt-shelters";
          WorkingDirectory = "/var/lib/lt-shelters";
          LoadCredential = [ "ssh-key:${cfg.sshKeyPath}" ];
          ExecStart = lib.getExe update;
          TimeoutStartSec = "3h";
          UMask = "0022";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/www/dl/maps" ];
        };
      };

      timers.lt-shelters = {
        description = "Weekly Lithuanian shelter and map data snapshot";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Mon *-*-* 04:17:00 Europe/Vilnius";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    };

    mj.base.unitstatus.units = [ "lt-shelters" ];
  };
}

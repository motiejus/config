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
  syncRepo = ''
    sync_repo() {
      local object_format="$1" url="$2" repo="$3"
      if [ ! -d "$repo/.git" ]; then
        GIT_DEFAULT_HASH="$object_format" git clone --branch main "$url" "$repo"
      else
        git -C "$repo" remote set-url origin "$url"
        GIT_DEFAULT_HASH="$object_format" git -C "$repo" fetch origin main
        git -C "$repo" reset --hard origin/main
      fi
      test "$(git -C "$repo" rev-parse --show-object-format)" = "$object_format"
    }
  '';
  # Daily timer, weekly work: a failed run retries tomorrow, not next week.
  # Half a day under a week so a slightly later start still counts as due and
  # the cadence cannot ratchet to eight days. $2 is the job's own output; a
  # path no commit ever touched reads as due, which is what :-0 buys -- drop
  # it and the arithmetic errors to stderr and runs on, gating nothing. Call
  # only after sync_repo, which fails first on a repo git cannot read.
  refreshGate = ''
    exit_unless_due() {
      local committed_at
      committed_at=$(git -C "$1" log -1 --format=%ct -- "$2")
      [ $(( $(date +%s) - ''${committed_at:-0} )) -ge $(( 7 * 86400 - 12 * 3600 )) ] ||
        { echo "$2 is fresh; not querying upstream"; exit 0; }
    }
  '';
  updateShelters = pkgs.writeShellApplication {
    name = "update-lt-shelters";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.lt-shelters
      pkgs.openssh
    ];
    text = ''
      set -x

      ${syncRepo}
      ${refreshGate}
      shelters_repo="$STATE_DIRECTORY/repo"
      export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o IdentitiesOnly=yes -o SendEnv=GIT_DEFAULT_HASH"

      sync_repo sha256 git@git.jakstys.lt:lt-shelters.git "$shelters_repo"

      exit_unless_due "$shelters_repo" refreshed-at.txt

      git -C "$shelters_repo" config user.name "Lithuanian shelter data bot"
      git -C "$shelters_repo" config user.email lt-shelters@jakstys.lt
      install -m 0644 ${readme} "$shelters_repo/README.md"
      install -m 0644 ${dataLicense} "$shelters_repo/LICENSE-DATA.md"
      fetch-priedangos "$shelters_repo/priedangos.jsonl"
      fetch-kas "$shelters_repo/kas.jsonl"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$shelters_repo/refreshed-at.txt"
      git -C "$shelters_repo" add README.md LICENSE-DATA.md priedangos.jsonl kas.jsonl refreshed-at.txt
      if ! git -C "$shelters_repo" diff --cached --quiet; then
        git -C "$shelters_repo" commit -m "Update PAGD shelter data"
        GIT_DEFAULT_HASH=sha256 git -C "$shelters_repo" push origin main
      fi
    '';
  };
  updateMaps = pkgs.writeShellApplication {
    name = "update-lt-maps";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.gnutar
      pkgs.jq
      pkgs.nix
      pkgs.openssh
      pkgs.wget
    ];
    text = ''
      set -x

      ${syncRepo}
      ${refreshGate}
      shelters_repo="$STATE_DIRECTORY/lt-shelters"
      lt_maps_repo="$STATE_DIRECTORY/repo"
      publish_dir=/var/www/dl/maps
      export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o IdentitiesOnly=yes -o SendEnv=GIT_DEFAULT_HASH"

      tmp_dir=$(mktemp -d "$STATE_DIRECTORY/update.XXXXXX")
      cleanup() {
        rm -rf -- "$tmp_dir"
      }
      publish_file() {
        local publish_tmp
        publish_tmp=$(mktemp "$publish_dir/.tmp-publish.XXXXXX")
        install -m 0644 "$1" "$publish_tmp"
        mv -f "$publish_tmp" "$2"
      }
      trap cleanup EXIT

      sync_repo sha1 git@git.jakstys.lt:lt-maps.git "$lt_maps_repo"
      exit_unless_due "$lt_maps_repo" nix/data-sources.json
      manifest="$lt_maps_repo/nix/data-sources.json"

      find "$publish_dir" -maxdepth 1 -type f -name '.tmp-*' -delete

      sync_repo sha256 https://git.jakstys.lt/lt-shelters.git "$shelters_repo"
      shelters_rev=$(git -C "$shelters_repo" rev-parse HEAD)
      shelters_tree="$tmp_dir/shelters"
      mkdir "$shelters_tree"
      git -C "$shelters_repo" archive "$shelters_rev" | tar -x -C "$shelters_tree"
      shelters_hash=$(nix-hash --type sha256 --sri "$shelters_tree")

      geofabrik=https://download.geofabrik.de/europe
      wget_args=(--progress=dot:giga --tries=5 --timeout=30 --retry-connrefused --retry-on-host-error "--retry-on-http-error=429,500,502,503,504")
      remote_md5_file="$tmp_dir/lithuania-latest.osm.pbf.md5"
      wget "''${wget_args[@]}" --output-document="$remote_md5_file" "$geofabrik/lithuania-latest.osm.pbf.md5"
      read -r remote_md5 _ < "$remote_md5_file"
      if [[ ! "$remote_md5" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "unexpected Geofabrik checksum: $(cat "$remote_md5_file")" >&2
        exit 1
      fi
      remote_md5="''${remote_md5,,}"

      pbf_name=
      for candidate_md5_target in "$publish_dir"/lithuania-*.osm.pbf.md5; do
        [ -e "$candidate_md5_target" ] || continue
        read -r candidate_md5 _ < "$candidate_md5_target" || continue
        if [ "''${candidate_md5,,}" = "$remote_md5" ]; then
          pbf_target="''${candidate_md5_target%.md5}"
          [ -e "$pbf_target" ] || continue
          pbf_name="''${pbf_target##*/}"
          break
        fi
      done

      if [ -z "$pbf_name" ]; then
        wget "''${wget_args[@]}" --trust-server-names --directory-prefix="$tmp_dir" "$geofabrik/lithuania-latest.osm.pbf"
        pbf_tmp=$(find "$tmp_dir" -maxdepth 1 -type f -name 'lithuania-*.osm.pbf' -print -quit)
        pbf_name="''${pbf_tmp##*/}"
        case "$pbf_name" in
          lithuania-[0-9][0-9][0-9][0-9][0-9][0-9].osm.pbf) ;;
          *) echo "unexpected Geofabrik filename: $pbf_name" >&2; exit 1 ;;
        esac
        if [ "$(md5sum "$pbf_tmp" | cut -d' ' -f1)" != "$remote_md5" ]; then
          echo "downloaded PBF checksum does not match Geofabrik checksum" >&2
          exit 1
        fi
        pbf_target="$publish_dir/$pbf_name"
        md5_tmp="$tmp_dir/$pbf_name.md5"
        printf '%s  %s\n' "$remote_md5" "$pbf_name" > "$md5_tmp"
        publish_file "$pbf_tmp" "$pbf_target"
        publish_file "$md5_tmp" "$pbf_target.md5"
      fi

      pbf_hex=$(sha256sum "$pbf_target" | cut -d' ' -f1)
      pbf_hash=$(nix hash convert --hash-algo sha256 --from base16 --to sri "$pbf_hex")
      pbf_url="https://dl.jakstys.lt/maps/$pbf_name"

      manifest_tmp="$tmp_dir/data-sources.json"
      jq --arg pbf_url "$pbf_url" --arg pbf_hash "$pbf_hash" --arg shelters_rev "$shelters_rev" --arg shelters_hash "$shelters_hash" '.osm.url = $pbf_url | .osm.hash = $pbf_hash | .shelters.url = "https://git.jakstys.lt/lt-shelters.git" | .shelters.rev = $shelters_rev | .shelters.hash = $shelters_hash' "$manifest" > "$manifest_tmp"
      mv "$manifest_tmp" "$manifest"

      git -C "$lt_maps_repo" config user.name "Lithuanian map data bot"
      git -C "$lt_maps_repo" config user.email lt-maps@jakstys.lt
      git -C "$lt_maps_repo" add -- nix/data-sources.json
      if ! git -C "$lt_maps_repo" diff --cached --quiet; then
        (cd "$lt_maps_repo"; nix build --no-warn-dirty --accept-flake-config --no-link .#check)
        git -C "$lt_maps_repo" commit -m "Update Lithuania map data sources"
        GIT_DEFAULT_HASH=sha1 git -C "$lt_maps_repo" push origin main
      fi

      # Keep the PBF referenced by the current manifest. Superseded PBFs and
      # their checksums remain downloadable for approximately three months.
      find "$publish_dir" -maxdepth 1 -type f -name 'lithuania-*.osm.pbf.md5' ! -name "$pbf_name.md5" -mtime +93 -delete
      find "$publish_dir" -maxdepth 1 -type f -name 'lithuania-*.osm.pbf' ! -name "$pbf_name" -mtime +93 -delete
    '';
  };
  mkUpdaterService =
    {
      description,
      user,
      program,
      onSuccess ? [ ],
      readWritePaths ? [ ],
    }:
    {
      inherit description;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        StateDirectory = user;
        LoadCredential = [ "ssh-key:/etc/ssh/ssh_host_ed25519_key" ];
        ExecStart = lib.getExe program;
        TimeoutStartSec = "3h";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      }
      // lib.optionalAttrs (readWritePaths != [ ]) {
        ReadWritePaths = readWritePaths;
      };
    }
    // lib.optionalAttrs (onSuccess != [ ]) {
      unitConfig.OnSuccess = onSuccess;
    };
in
{
  options.mj.services.lt-shelters.enable =
    lib.mkEnableOption "periodic Lithuanian shelter and map data snapshots";

  config = lib.mkIf cfg.enable {
    users = {
      users.lt-shelters = {
        description = "Lithuanian shelter data bot";
        isSystemUser = true;
        group = "lt-shelters";
        home = "/var/lib/lt-shelters";
        uid = myData.uidgid.lt-shelters;
      };
      groups.lt-shelters.gid = myData.uidgid.lt-shelters;
      users.lt-maps = {
        description = "Lithuanian map data bot";
        isSystemUser = true;
        group = "lt-maps";
        home = "/var/lib/lt-maps";
        uid = myData.uidgid.lt-maps;
      };
      groups.lt-maps.gid = myData.uidgid.lt-maps;
    };
    systemd = {
      tmpfiles.rules = [
        "d /var/www/dl/maps 0755 lt-maps lt-maps -"
      ];

      services.lt-shelters = mkUpdaterService {
        description = "Snapshot Lithuanian shelter data";
        user = "lt-shelters";
        program = updateShelters;
        onSuccess = [ "lt-maps.service" ];
      };

      services.lt-maps = mkUpdaterService {
        description = "Publish Lithuania PBF and update map data pins";
        user = "lt-maps";
        program = updateMaps;
        readWritePaths = [ "/var/www/dl/maps" ];
      };

      # Geofabrik publishes the Lithuania extract overnight; run after it
      # lands, on Geofabrik's own clock so summer time cannot eat the margin.
      timers.lt-shelters = {
        description = "Daily attempt at a Lithuanian shelter and map data refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 04:00:00 UTC";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };
    };

    mj.base.unitstatus.units = [
      "lt-shelters"
      "lt-maps"
    ];
  };
}

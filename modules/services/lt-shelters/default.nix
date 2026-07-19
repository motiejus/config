{
  config,
  lib,
  pkgs,
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

    The snapshots are refreshed daily. A commit is created only when the
    source bytes change. See LICENSE-DATA.md for reuse terms and attribution.
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
      pkgs.git
      cfg.package
      pkgs.openssh
    ];
    text = ''
      repo="$STATE_DIRECTORY/repo"
      export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o IdentitiesOnly=yes -o SendEnv=GIT_DEFAULT_HASH"

      if [ ! -d "$repo/.git" ]; then
        mkdir -p "$repo"
        git -C "$repo" init --object-format=sha256 --initial-branch=main
      fi

      # Complete a partially initialized state and follow configuration if the
      # destination changes later.
      if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
        git -C "$repo" remote set-url origin ${lib.escapeShellArg cfg.repo}
      else
        git -C "$repo" remote add origin ${lib.escapeShellArg cfg.repo}
      fi

      # The remote repository or its main branch may not exist yet, and a
      # previous initial push may have failed after creating the local commit.
      # Preserve that commit and retry the push instead of stranding it.
      if git -C "$repo" fetch origin main; then
        git -C "$repo" reset --hard origin/main
      fi

      test "$(git -C "$repo" rev-parse --show-object-format)" = sha256
      git -C "$repo" config user.name ${lib.escapeShellArg cfg.gitUserName}
      git -C "$repo" config user.email ${lib.escapeShellArg cfg.gitUserEmail}

      install -m 0644 ${readme} "$repo/README.md"
      install -m 0644 ${dataLicense} "$repo/LICENSE-DATA.md"
      fetch-priedangos "$repo/priedangos.jsonl"
      fetch-kas "$repo/kas.jsonl"

      git -C "$repo" add README.md LICENSE-DATA.md priedangos.jsonl kas.jsonl
      if ! git -C "$repo" diff --cached --quiet; then
        git -C "$repo" commit -m "Update PAGD shelter data"
      fi

      # Always push: this is a no-op when origin is current, and retries a
      # commit left behind by an earlier transport or create-on-push failure.
      GIT_DEFAULT_HASH=sha256 git -C "$repo" push --set-upstream origin main
    '';
  };
in
{
  options.mj.services.lt-shelters = {
    enable = lib.mkEnableOption "periodic Lithuanian PAGD shelter dataset snapshots";
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
      description = "SSH private key used to push snapshots";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.lt-shelters = {
      description = "Snapshot Lithuania's Priedanga and KAS open data";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.GIT_DEFAULT_HASH = "sha256";
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        StateDirectory = "lt-shelters";
        WorkingDirectory = "/var/lib/lt-shelters";
        LoadCredential = [ "ssh-key:${cfg.sshKeyPath}" ];
        ExecStart = lib.getExe update;
      };
    };

    # Daily matches observed batch updates (median active-day gaps of 2 days
    # for Priedanga and 3 days for KAS). Jitter avoids a fixed portal spike.
    systemd.timers.lt-shelters = {
      description = "Daily Lithuanian shelter data snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:17:00 Europe/Vilnius";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    mj.base.unitstatus.units = [ "lt-shelters" ];
  };
}

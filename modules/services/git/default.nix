{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.git;

  # stagit-ng is a client-side (wasm) repo browser: the vhost serves its
  # static frontend at the root (the shipped index.html defaults derive
  # site title and clone urls from the request origin), the bare
  # repositories under *.git/ (dumb HTTP), and a repositories.txt that
  # drives the repository index page. The only per-repo server-side work
  # is `git update-server-info` plus regenerating repositories.txt on
  # pushes and repo creation.

  repolistGen = pkgs.writeShellApplication {
    name = "git-repolist-gen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
    ];
    # repositories.txt drives stagit-ng's index page. Each line is
    # tab-separated: "<path>.git \t <HEAD commit epoch> \t <owner> \t
    # <description>", sorted newest-first — so the index renders from one
    # fetch with no per-repo work on the client.
    text = ''
      tmp=$(mktemp "${cfg.repoDir}/.repositories.txt.XXXXXX")
      cd "${cfg.repoDir}"
      find . -mindepth 1 -maxdepth 2 -name '*.git' -type d | sed 's|^\./||' | while read -r p; do
        epoch=$(git -C "$p" log -1 --format=%ct 2>/dev/null || true)
        owner=$(head -1 "$p/owner" 2>/dev/null || true)
        desc=$(head -1 "$p/description" 2>/dev/null || true)
        case "$desc" in "Unnamed repository"*) desc="" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$p" "''${epoch:-0}" "$owner" "$desc"
      done | sort -t"$(printf '\t')" -k2,2 -rn > "$tmp"
      chmod 644 "$tmp"
      mv "$tmp" "${cfg.repoDir}/repositories.txt"
    '';
  };

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = [
      pkgs.git
    ];
    text = ''
      # single pack per repo: keeps stagit-ng's oid lookups single-shot
      # (gc also packs refs, which keeps packed-refs current)
      git gc --quiet || true
      git update-server-info

      # Persist metadata from push options: git push -o description=... -o owner=...
      count="''${GIT_PUSH_OPTION_COUNT:-0}"
      i=0
      while [ "$i" -lt "$count" ]; do
        name="GIT_PUSH_OPTION_$i"
        opt="''${!name}"
        # Strip tabs so a value cannot inject extra columns into the
        # tab-separated repositories.txt (git already forbids newlines here).
        case "$opt" in
        description=*)
          v="''${opt#description=}"
          printf '%s\n' "''${v//$'\t'/}" > description
          ;;
        owner=*)
          v="''${opt#owner=}"
          printf '%s\n' "''${v//$'\t'/}" > owner
          ;;
        esac
        i=$((i + 1))
      done

      ${repolistGen}/bin/git-repolist-gen
    '';
  };

  newRepo = pkgs.writeShellApplication {
    name = "git-new-repo";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = ''
      if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        echo "Usage: git-new-repo <org/name> [description]" >&2
        exit 1
      fi

      repopath="${cfg.repoDir}/$1.git"

      if [ ! -d "$repopath" ]; then
        mkdir -p "$(dirname "$repopath")"
        git init --bare "$repopath"
        echo "Created $repopath"
      fi

      git config -f "$repopath/config" core.sharedRepository 0644
      # allow `git push -o description=... -o owner=...` (parsed by the hook)
      git config -f "$repopath/config" receive.advertisePushOptions true

      if [ -n "''${2:-}" ]; then
        printf '%s\n' "$2" > "$repopath/description"
      fi

      ln -sf "${cfg.repoDir}/.post-receive-hook" "$repopath/hooks/post-receive"
      git -C "$repopath" update-server-info
      ${repolistGen}/bin/git-repolist-gen
    '';
  };

  gitShellWrapper = pkgs.writeShellApplication {
    name = "git-shell-wrapper";
    runtimeInputs = with pkgs; [
      coreutils
      git
      newRepo
    ];
    text = ''
      # sshd invokes the login shell as: git-shell-wrapper -c "<git command>"
      # Anything else (e.g. an interactive login) is handed to git-shell,
      # which refuses it.
      if [ "$#" -ne 2 ] || [ "$1" != "-c" ]; then
        exec ${pkgs.git}/bin/git-shell "$@"
      fi

      # Create-on-push: git-receive-pack against a missing repo would fail, so
      # create it first (org/name.git under repoDir, with hook + perms). git
      # sends the path single-quoted, e.g. git-receive-pack 'motiejus/foo.git'.
      case "$2" in
      "git-receive-pack "*)
        path="''${2#git-receive-pack }" # 'motiejus/foo.git'
        path="''${path#\'}"             # motiejus/foo.git'
        path="''${path%\'}"             # motiejus/foo.git
        rel="''${path%.git}"
        # Reject traversal and absolute paths: git-new-repo would otherwise
        # init a bare repo outside repoDir, and an absolute path here would
        # not match what git-shell resolves for the actual receive-pack.
        case "$rel" in
        *..* | /*)
          echo "invalid repo path: $path" >&2
          exit 1
          ;;
        */*) git-new-repo "$rel" >&2 ;;
        *)
          echo "repo path must be org/name(.git): $path" >&2
          exit 1
          ;;
        esac
        ;;
      esac

      exec ${pkgs.git}/bin/git-shell "$@"
    '';
  };
in
{
  options.mj.services.git = with lib.types; {
    enable = lib.mkEnableOption "git web hosting with stagit-ng";
    repoDir = lib.mkOption { type = str; };
    sshKeys = lib.mkOption {
      type = listOf str;
      default = [ ];
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.mj.services.gitea.enable;
        message = "git and gitea cannot be enabled simultaneously (both define the git user)";
      }
    ];

    users.users.git = {
      description = "Git";
      home = cfg.repoDir;
      shell = "${gitShellWrapper}/bin/git-shell-wrapper";
      group = "git";
      isSystemUser = true;
      createHome = true;
      homeMode = "755";
      uid = myData.uidgid.gitea;
      openssh.authorizedKeys.keys = cfg.sshKeys;
    };

    users.groups.git.gid = myData.uidgid.gitea;

    services.openssh.extraConfig = ''
      AcceptEnv GIT_PROTOCOL
    '';

    # repositories.txt is regenerated by the post-receive hook and by
    # git-new-repo. For a first deploy with pre-existing repos, seed it once
    # (alongside the one-time `git update-server-info` pass) with
    # `sudo -u git git-repolist-gen`.
    systemd.tmpfiles.rules = [
      "L+ ${cfg.repoDir}/.post-receive-hook - - - - ${postReceiveHook}/bin/post-receive"
    ];

    environment.systemPackages = [
      newRepo
      repolistGen # exposed for the one-time bootstrap above
    ];

    services.caddy.virtualHosts."git.jakstys.lt".extraConfig = ''
      header {
        Strict-Transport-Security "max-age=15768000"
        Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Alt-Svc "h3=\":443\"; ma=86400"
      }

      route {
        # Bare repos (dumb HTTP) and the repo list both live in repoDir.
        @repo path_regexp (\.git/|^/repositories\.txt$)
        handle @repo {
          root * ${cfg.repoDir}
          file_server
        }
        handle {
          root * ${pkgs.stagit-ng}/www
          file_server
        }
      }
    '';
  };
}

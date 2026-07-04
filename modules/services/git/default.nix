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
  # lists them (paths only; the client fetches per-repo details). The
  # only server-side work is `git update-server-info` on push plus
  # regenerating repositories.txt on repo creation.

  repolistGen = pkgs.writeShellApplication {
    name = "git-repolist-gen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    # repositories.txt drives stagit-ng's index page: one repo path per
    # line, nothing else — the client fetches each repo's description and
    # last-commit date itself. Only needs regenerating when a repo is
    # created or removed.
    text = ''
      tmp=$(mktemp "${cfg.repoDir}/.repositories.txt.XXXXXX")
      cd "${cfg.repoDir}"
      find . -mindepth 1 -maxdepth 2 -name '*.git' -type d | sed 's|^\./||' | sort > "$tmp"
      chmod 644 "$tmp"
      mv "$tmp" "${cfg.repoDir}/repositories.txt"
    '';
  };

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = [
      pkgs.git
      pkgs.util-linux # setsid
    ];
    text = ''
      # Fast path first, so the push returns and the new commits are
      # immediately visible to stagit-ng; gc runs detached below.
      git update-server-info

      # Persist metadata from push options: git push -o description=...
      # (the description file is read per-repo by the stagit-ng client)
      count="''${GIT_PUSH_OPTION_COUNT:-0}"
      i=0
      while [ "$i" -lt "$count" ]; do
        name="GIT_PUSH_OPTION_$i"
        opt="''${!name}"
        case "$opt" in
        description=*)
          printf '%s\n' "''${opt#description=}" > description
          ;;
        esac
        i=$((i + 1))
      done

      # repositories.txt only lists paths, so pushes don't touch it;
      # git-new-repo regenerates it when a repo is created.

      # single pack per repo: keeps stagit-ng's oid lookups single-shot
      # (gc also packs refs, which keeps packed-refs current). gc can take
      # a while, so it runs detached from the push; update-server-info must
      # run again afterwards because repacking rewrites objects/info/packs
      # (dumb-HTTP clients would otherwise fetch deleted packs). Concurrent
      # pushes are fine: gc's own gc.pid lock makes the loser skip, and the
      # trailing update-server-info still runs.
      setsid -f ${pkgs.runtimeShell} -c 'git gc --quiet; git update-server-info' >/dev/null 2>&1 </dev/null
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
      # allow `git push -o description=...` (parsed by the hook)
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
    users.users.git = {
      description = "Git";
      home = cfg.repoDir;
      shell = "${gitShellWrapper}/bin/git-shell-wrapper";
      group = "git";
      isSystemUser = true;
      createHome = true;
      homeMode = "755";
      uid = myData.uidgid.git;
      openssh.authorizedKeys.keys = cfg.sshKeys;
    };

    users.groups.git.gid = myData.uidgid.git;

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
        # connect-src https: (not 'self'): stagit-ng's standalone form can
        # browse remote repositories from this origin too.
        Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src https:"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Alt-Svc "h3=\":443\"; ma=86400"
      }

      route {
        # Bare repos (dumb HTTP) and the repo list both live in repoDir.
        # The CORS headers let stagit-ng frontends hosted elsewhere (e.g.
        # standalone mode on localhost) browse these repos: public
        # read-only data, GET/HEAD only. Preflight is needed because a
        # cross-origin Range GET is never a "simple" request, and
        # Content-Range must be exposed for the client to learn file sizes.
        # No Cache-Control here: repo-data cache policy is client-owned
        # (stagit-ng.js force-caches content-addressed pack/object files
        # and revalidates the mutable rest; repo files have real mtimes,
        # so Caddy's ETags make those revalidations cheap 304s).
        @repo path_regexp (\.git/|^/repositories\.txt$)
        @repo_preflight {
          method OPTIONS
          path_regexp (\.git/|^/repositories\.txt$)
        }
        handle @repo_preflight {
          header {
            Access-Control-Allow-Origin "*"
            Access-Control-Allow-Methods "GET, HEAD, OPTIONS"
            Access-Control-Allow-Headers "Range"
            Access-Control-Max-Age "86400"
          }
          respond 204
        }
        handle @repo {
          header {
            Access-Control-Allow-Origin "*"
            Access-Control-Expose-Headers "Content-Range"
          }
          root * ${cfg.repoDir}
          file_server
        }
        handle {
          # no-cache: browsers store the frontend but revalidate on every
          # use; unchanged files are cheap 304s, deploys show on the next
          # load. The 304s exist only because of the content-hash .etag
          # sidecars generated in pkgs/stagit-ng.nix: caddy sends no
          # validators at all for nix-store files (epoch mtimes fail its
          # usefulModTime check), so plain no-cache would re-download
          # full bodies every load.
          header Cache-Control "no-cache"
          root * ${pkgs.stagit-ng}/www
          file_server {
            precompressed zstd br gzip
            etag_file_extensions .etag
          }
        }
      }
    '';
  };
}

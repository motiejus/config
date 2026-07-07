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
  # static frontend (assets under /_/, index.html as the SPA shell for
  # every app route — the client reads the route from the location, in
  # path-routing mode), the bare repositories under *.git/ (dumb HTTP),
  # and a repositories.txt that lists them (paths only; the client fetches
  # per-repo details). The only server-side work is `git update-server-info`
  # on push plus regenerating repositories.txt on repo creation.

  repolistGen = pkgs.writeShellApplication {
    name = "git-repolist-gen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
    ];
    # repositories.txt drives stagit-ng's index page: one repo path per
    # line, nothing else — the client fetches each repo's description and
    # last-commit date itself, and renders rows in list order (it never
    # reorders under the reader), so newest-first is decided here: sort by
    # HEAD's committer date, the same value the client shows. Regenerated
    # on repo creation and on every push (a push changes the order).
    text = ''
      tmp=$(mktemp "${cfg.repoDir}/.repositories.txt.XXXXXX")
      cd "${cfg.repoDir}"
      find . -mindepth 1 -maxdepth 1 -name '*.git' -type d | sed 's|^\./||' | sort | while read -r r; do
        printf '%s\t%s\n' "$(git -C "$r" log -1 --format=%ct 2>/dev/null || echo 0)" "$r"
      done | sort -rns -k1,1 | cut -f2- > "$tmp"
      chmod 644 "$tmp"
      mv "$tmp" "${cfg.repoDir}/repositories.txt"
    '';
  };

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = [
      pkgs.coreutils # head
      pkgs.git
      pkgs.util-linux # setsid
    ];
    text = ''
      # Fast path first, so the push returns and the new commits are
      # immediately visible to stagit-ng; gc runs detached below.
      git update-server-info

      # git init points HEAD at git's default branch name; when the first
      # push brings differently-named branches (e.g. `main`), HEAD dangles:
      # clones check out nothing and stagit-ng has no default branch.
      # Repoint it at the first branch present. (Pushes never move HEAD,
      # so a later delete of the default branch is repaired here too.)
      head_ref=$(git symbolic-ref HEAD)
      if ! git show-ref --verify --quiet "$head_ref"; then
        first_ref=$(git for-each-ref --format='%(refname)' refs/heads | head -n 1)
        if [ -n "$first_ref" ]; then
          git symbolic-ref HEAD "$first_ref"
        fi
      fi

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

      # repositories.txt is ordered by last commit date, so a push can
      # reorder it (cheap: one `git log -1` per repo).
      ${repolistGen}/bin/git-repolist-gen

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
        echo "Usage: git-new-repo <name> [description]" >&2
        exit 1
      fi

      # Flat namespace: repos are name.git directly under repoDir. Reject a
      # path separator or traversal so a repo cannot be created elsewhere.
      case "$1" in
      "" | */* | *..*)
        echo "invalid repo name: '$1' (flat name, no '/')" >&2
        exit 1
        ;;
      esac

      repopath="${cfg.repoDir}/$1.git"

      if [ ! -d "$repopath" ]; then
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

      # Object format for create-on-push. The server cannot learn the
      # client's format from the protocol (receive-pack advertises first,
      # the client just aborts on mismatch), so sha256 pushers opt in via
      # the ssh environment: GIT_DEFAULT_HASH=sha256 on the push, with
      # `SendEnv GIT_DEFAULT_HASH` for this host in their ssh config
      # (sshd's AcceptEnv below admits it). git init inside git-new-repo
      # honors the variable natively; only known values pass through.
      case "''${GIT_DEFAULT_HASH:-}" in
      sha1 | sha256) ;;
      *) unset GIT_DEFAULT_HASH ;;
      esac

      # Create-on-push: git-receive-pack against a missing repo would fail, so
      # create it first (name.git under repoDir, with hook + perms). git
      # sends the path single-quoted, e.g. git-receive-pack 'foo.git'.
      case "$2" in
      "git-receive-pack "*)
        path="''${2#git-receive-pack }" # 'foo.git'
        path="''${path#\'}"             # foo.git'
        path="''${path%\'}"             # foo.git
        rel="''${path%.git}"
        # Flat namespace: a bare repo name only. Reject a path separator
        # (owner prefix, traversal, or an absolute path — */* covers them
        # all, a glob * also matches the empty string) — git-new-repo would
        # otherwise init a bare repo outside repoDir.
        case "$rel" in
        "" | */* | *..*)
          echo "invalid repo path: $path (flat name, no '/')" >&2
          exit 1
          ;;
        *) git-new-repo "$rel" >&2 ;;
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

    # GIT_DEFAULT_HASH: see the create-on-push comment in git-shell-wrapper.
    services.openssh.extraConfig = ''
      AcceptEnv GIT_PROTOCOL GIT_DEFAULT_HASH
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
      # Transport-level headers only: the app's security headers (CSP,
      # nosniff, X-Frame-Options) come from the imported Caddyfile.snippet
      # below — they are stagit-ng's policy (the CSP whitelists the app's
      # own wasm/logo), and duplicating a CSP here would enforce the
      # intersection of the two.
      header {
        Strict-Transport-Security "max-age=15768000"
        Alt-Svc "h3=\":443\"; ma=86400"
      }

      # stagit-ng is path-routed: the browser URL is the route itself, read
      # from location.pathname; app routes fall back to the SPA shell. The
      # whole routing contract (assets under /_/, the closed git-data set +
      # CORS, the SPA fallback) is stagit-ng's deploy/Caddyfile.snippet,
      # imported below with this vhost's two roots — the same snippet the
      # repo's integration suite validates, so this config cannot drift from
      # it. (Requires pkgs.stagit-ng built from a rev that ships deploy/.)
      #
      # The deployment-specific migration shims go before the import: route{}
      # preserves source order, so they run ahead of the snippet's catch-all
      # SPA fallback. They cannot steal the snippet's real traffic: @oldclone
      # needs two path segments before the data file (flat data paths have
      # one; in principle it also matches /_/x.git/HEAD, but no such asset
      # exists), and @undocker is one exact browse path.
      route {
        # Migration shim: old owner-qualified clone URLs (/owner/repo.git/…)
        # still pinned out in the wild — e.g. nixpkgs' undocker ref,
        # https://git.jakstys.lt/motiejus/undocker.git — redirect to the flat
        # data path so `git clone`/fetchgit keep working until those refs are
        # updated. `git` follows the redirect on the initial info/refs and
        # re-homes to the flat base; the query MUST be preserved, since git
        # derives the new base by stripping the request suffix (path AND
        # ?service=…) and rejects a redirect whose suffix differs. Scoped to
        # the git-data file set so it never rewrites an app route. REMOVE once
        # no stale refs remain.
        @oldclone path_regexp oldclone ^/[^/]+/([^/]+\.git/(HEAD|info/refs|packed-refs|description|objects/.*))$
        handle @oldclone {
          redir * /{re.oldclone.1}?{query} 302
        }

        # Migration shim (browse link): the one owner-qualified app URL still
        # pinned in the wild — nixpkgs' undocker homepage/meta,
        # https://git.jakstys.lt/motiejus/undocker — redirects to its flat
        # route. Exact path only (the clone/data paths are handled above).
        # REMOVE once that ref is updated. Both the bare and trailing-slash
        # forms, exact — not a prefix glob, which would also catch
        # /motiejus/undocker.git/… (handled above) and /motiejus/undockerX.
        @undocker path /motiejus/undocker /motiejus/undocker/
        redir @undocker /undocker 302

        import ${pkgs.stagit-ng}/deploy/Caddyfile.snippet ${pkgs.stagit-ng}/www ${cfg.repoDir}
      }
    '';
  };
}

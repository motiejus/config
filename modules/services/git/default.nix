{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.git;
  cacheDir = "${cfg.wwwDir}/.cache";

  stagit = pkgs.stagit.overrideAttrs {
    src = builtins.fetchGit {
      url = "https://git.jakstys.lt/motiejus/stagit.git";
      ref = "master";
      rev = "220e16ad4216c05b54832e885a188e05b54048f5";
    };
  };
  stagitAssets = "${pkgs.stagit.src}";

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      stagit
    ];
    text = ''
      repo="$(pwd)"
      reponame="$(realpath --relative-to="${cfg.repoDir}" "$repo")"
      reponame="''${reponame%.git}"
      orgname="$(dirname "$reponame")"

      git update-server-info

      outdir="${cfg.wwwDir}/$reponame"
      mkdir -p "$outdir"
      cachefile="${cacheDir}/$reponame"
      mkdir -p "$(dirname "$cachefile")"

      cd "$outdir"
      stagit -c "$cachefile" "$repo"

      if [ ! -f "$outdir/index.html" ]; then
        ln -sf log.html "$outdir/index.html"
      fi

      for f in style.css favicon.png logo.png; do
        cp -f "${stagitAssets}/$f" "$outdir/$f"
      done

      for r in "${cfg.repoDir}"/*/*.git; do
        printf '%s %s\n' "$(git -C "$r" log -1 --format=%ct 2>/dev/null || echo 0)" "$r"
      done | sort -rn | cut -d' ' -f2- | xargs stagit-index \
        > "${cfg.wwwDir}/$orgname/index.html"

      for f in style.css favicon.png logo.png; do
        cp -f "${stagitAssets}/$f" "${cfg.wwwDir}/$orgname/$f"
      done
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

      if [ -n "''${2:-}" ]; then
        printf '%s\n' "$2" > "$repopath/description"
      fi

      ln -sf "${cfg.repoDir}/.post-receive-hook" "$repopath/hooks/post-receive"
    '';
  };
in
{
  options.mj.services.git = with lib.types; {
    enable = lib.mkEnableOption "git web hosting with stagit";
    repoDir = lib.mkOption { type = str; };
    wwwDir = lib.mkOption { type = str; };
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
      shell = "${pkgs.git}/bin/git-shell";
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

    systemd.tmpfiles.rules = [
      "d ${cfg.wwwDir} 0755 git git -"
      "L+ ${cfg.repoDir}/.post-receive-hook - - - - ${postReceiveHook}/bin/post-receive"
    ];

    environment.systemPackages = [ newRepo ];

    services.caddy.virtualHosts."git.jakstys.lt".extraConfig = ''
      header {
        Strict-Transport-Security "max-age=15768000"
        Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Alt-Svc "h3=\":443\"; ma=86400"
      }

      route {
        redir / /motiejus/ 302

        @git_clone path_regexp \.git/
        handle @git_clone {
          root * ${cfg.repoDir}
          file_server
        }
        handle {
          root * ${cfg.wwwDir}
          file_server
        }
      }
    '';
  };
}

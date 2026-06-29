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
  dirtyDir = "${cfg.wwwDir}/.dirty";

  stagit = pkgs.stagit.overrideAttrs {
    src = builtins.fetchGit {
      url = "https://git.jakstys.lt/motiejus/stagit.git";
      ref = "master";
      rev = "54d688765453529364644ed90f37543eb71a65f4";
    };
  };
  stagitAssets = "${pkgs.stagit.src}";

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      repo="$(pwd)"
      reponame="$(realpath --relative-to="${cfg.repoDir}" "$repo")"
      reponame="''${reponame%.git}"

      git update-server-info

      printf '%s\n' "$reponame" >> "${dirtyDir}/queue"
    '';
  };

  regenScript = pkgs.writeShellApplication {
    name = "stagit-regen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      stagit
    ];
    text = ''
      if [ -f "${dirtyDir}/queue.work" ]; then
        cat "${dirtyDir}/queue.work" >> "${dirtyDir}/queue" 2>/dev/null || true
      fi
      mv "${dirtyDir}/queue" "${dirtyDir}/queue.work" 2>/dev/null || exit 0

      declare -A repos
      declare -A orgs

      while IFS= read -r reponame; do
        repos["$reponame"]=1
        orgs["''${reponame%%/*}"]=1
      done < "${dirtyDir}/queue.work"

      for reponame in "''${!repos[@]}"; do
        repo="${cfg.repoDir}/''${reponame}.git"
        [ -d "$repo" ] || continue

        outdir="${cfg.wwwDir}/$reponame"
        mkdir -p "$outdir"
        cachefile="${cacheDir}/$reponame"
        mkdir -p "$(dirname "$cachefile")"

        (cd "$outdir" && stagit -c "$cachefile" -T${toString cfg.threads} "$repo") || continue

        if [ ! -f "$outdir/index.html" ]; then
          ln -sf log.html "$outdir/index.html"
        fi

        for f in style.css favicon.png logo.png; do
          cp -f "${stagitAssets}/$f" "$outdir/$f"
        done
      done

      for orgname in "''${!orgs[@]}"; do
        mkdir -p "${cfg.wwwDir}/$orgname"
        tmpidx=$(mktemp "${cfg.wwwDir}/''${orgname}/index.html.XXXXXX")
        for r in "${cfg.repoDir}/''${orgname}"/*.git; do
          [ -d "$r" ] || continue
          printf '%s %s\n' "$(git -C "$r" log -1 --format=%ct 2>/dev/null || echo 0)" "$r"
        done | sort -rn | cut -d' ' -f2- | xargs -r stagit-index > "$tmpidx"
        mv "$tmpidx" "${cfg.wwwDir}/''${orgname}/index.html"

        for f in style.css favicon.png logo.png; do
          cp -f "${stagitAssets}/$f" "${cfg.wwwDir}/''${orgname}/$f"
        done
      done

      rm -f "${dirtyDir}/queue.work"
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
    threads = lib.mkOption {
      type = int;
      default = 0;
      description = "Number of threads for stagit blob/tree generation (0 = auto-detect).";
    };
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
      "d ${dirtyDir} 0755 git git -"
      "L+ ${cfg.repoDir}/.post-receive-hook - - - - ${postReceiveHook}/bin/post-receive"
    ];

    systemd.services.stagit-regen = {
      description = "Regenerate stagit HTML pages";
      serviceConfig = {
        Type = "oneshot";
        User = "git";
        Group = "git";
        ExecStart = "${regenScript}/bin/stagit-regen";
      };
    };

    systemd.paths.stagit-regen = {
      description = "Watch for stagit regeneration triggers";
      pathConfig.PathExists = "${dirtyDir}/queue";
      wantedBy = [ "multi-user.target" ];
    };

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

{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
let
  cfg = config.mj.services.git;
  cacheDir = "/var/lib/git/.stagit-cache";

  styleCSS = "${pkgs.stagit.src}/style.css";

  postReceiveHook = pkgs.writeShellApplication {
    name = "post-receive";
    runtimeInputs = with pkgs; [
      coreutils
      git
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
      ln -sf log.html index.html

      stagit-index "${cfg.repoDir}"/*/*.git \
        > "${cfg.wwwDir}/index.html"

      cp -f ${styleCSS} "${cfg.wwwDir}/style.css"
      mkdir -p "${cfg.wwwDir}/$orgname"
      cp -f ${styleCSS} "${cfg.wwwDir}/$orgname/style.css"
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

      if [ -n "''${2:-}" ]; then
        printf '%s\n' "$2" > "$repopath/description"
      fi

      ln -sf ${postReceiveHook}/bin/post-receive "$repopath/hooks/post-receive"
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
      uid = myData.uidgid.gitea;
      openssh.authorizedKeys.keys = cfg.sshKeys;
    };

    users.groups.git.gid = myData.uidgid.gitea;

    services.openssh.extraConfig = ''
      AcceptEnv GIT_PROTOCOL
    '';

    systemd.tmpfiles.rules = [
      "d ${cfg.wwwDir} 0755 git git -"
      "d ${cacheDir} 0755 git git -"
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

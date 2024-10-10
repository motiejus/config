{
  config,
  lib,
  pkgs,
  myData,
  ...
}:
{
  options.mj.services.gitea = with lib.types; {
    enable = lib.mkEnableOption "Enable gitea";
  };

  config = lib.mkIf config.mj.services.gitea.enable {
    users = {
      users.git = {
        description = "Gitea Service";
        home = "/var/lib/gitea";
        shell = "/bin/sh";
        group = "gitea";
        isSystemUser = true;
        uid = myData.uidgid.gitea;
      };

      groups.gitea.gid = myData.uidgid.gitea;
    };

    services = {
      gitea = {
        enable = true;
        user = "git";
        database.user = "git";
        settings = {
          admin.DISABLE_REGULAR_ORG_CREATION = true;
          api.ENABLE_SWAGGER = false;
          mirror.ENABLED = false;
          other.SHOW_FOOTER_VERSION = false;
          packages.ENABLED = true;
          repo-archive.ENABLED = false;
          repository = {
            DEFAULT_REPO_UNITS = "repo.code,repo.releases";
            DISABLE_MIGRATIONS = true;
            DISABLE_STARS = true;
            ENABLE_PUSH_CREATE_USER = true;
          };
          security.LOGIN_REMEMBER_DAYS = 30;
          server = {
            STATIC_URL_PREFIX = "/static";
            ENABLE_GZIP = true;
            LANDING_PAGE = "/motiejus";
            ROOT_URL = "https://git.jakstys.lt";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = myData.ports.gitea;
            DOMAIN = "git.jakstys.lt";
          };
          service = {
            DISABLE_REGISTRATION = true;
            ENABLE_TIMETRACKING = false;
            ENABLE_USER_HEATMAP = false;
            SHOW_MILESTONES_DASHBOARD_PAGE = false;
            COOKIE_SECURE = true;
          };
          session.COOKIE_SECURE = true;
          log.LEVEL = "Error";
          mailer = {
            ENABLED = true;
            FROM = "<noreply@jakstys.lt>";
            PROTOCOL = "smtp";
            SMTP_ADDR = "localhost";
            SMTP_PORT = 25;
          };
          "service.explore".DISABLE_USERS_PAGE = true;
        };
      };

      openssh.extraConfig = ''
        AcceptEnv GIT_PROTOCOL
      '';

      caddy = {
        virtualHosts."git.jakstys.lt".extraConfig = ''
          route /static/assets/* {
            uri strip_prefix /static
            file_server * {
              root ${pkgs.pkgs-unstable.compressDrvWeb pkgs.gitea.data { }}/public
              precompressed zstd br gzip
            }
          }

          header {
            Strict-Transport-Security "max-age=15768000"

            # https://github.com/go-gitea/gitea/issues/305#issuecomment-1049290764
            Content-Security-Policy "frame-ancestors 'none'; default-src 'none'; connect-src 'self'; font-src 'self' data:; form-action 'self'; img-src 'self' https://ga-beacon.appspot.com https://raw.githubusercontent.com https://secure.gravatar.com https://sourcethemes.com; script-src 'self' 'unsafe-eval' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; worker-src 'self';"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Alt-Svc "h3=\":443\"; ma=86400"
          }

          reverse_proxy 127.0.0.1:${toString myData.ports.gitea}
        '';
      };
    };
  };
}

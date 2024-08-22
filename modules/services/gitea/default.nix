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
              precompressed br gzip
            }
          }

          reverse_proxy 127.0.0.1:${toString myData.ports.gitea}
        '';
      };
    };
  };
}

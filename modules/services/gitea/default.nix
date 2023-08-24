{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.services.gitea = with lib.types; {
    enable = lib.mkEnableOption "Enable gitea";
  };

  config = lib.mkIf config.mj.services.gitea.enable {
    users = {
      users.git = {
        description = "Gitea Service";
        home = "/var/lib/gitea";
        useDefaultShell = true;
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
          packages.ENABLED = false;
          repository = {
            DEFAULT_REPO_UNITS = "repo.code,repo.releases";
            DISABLE_MIGRATIONS = true;
            DISABLE_STARS = true;
            ENABLE_PUSH_CREATE_USER = true;
          };
          security.LOGIN_REMEMBER_DAYS = 30;
          server = {
            ENABLE_GZIP = true;
            LANDING_PAGE = "/motiejus";
            ROOT_URL = "https://git.jakstys.lt";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = 3000;
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
          # TODO: does not work with 1.19.4, getting error
          # in the UI when testing the email sending workflow.
          #mailer = {
          #    ENABLED = true;
          #    MAILER_TYPE = "sendmail";
          #    FROM = "<noreply@jakstys.lt>";
          #    SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
          #};
          "service.explore".DISABLE_USERS_PAGE = true;
        };
      };

      openssh.extraConfig = ''
        AcceptEnv GIT_PROTOCOL
      '';

      caddy = {
        virtualHosts."git.jakstys.lt".extraConfig = ''
          reverse_proxy 127.0.0.1:3000
        '';
      };
    };
  };
}

{
  config,
  lib,
  myData,
  ...
}:
let
  cfg = config.mj.services.grafana;
in
{
  options.mj.services.grafana = with lib.types; {
    enable = lib.mkEnableOption "enable grafana";
    port = lib.mkOption { type = port; };
    oidcSecretFile = lib.mkOption { type = str; };
  };

  config = lib.mkIf cfg.enable {
    services.grafana = {
      enable = true;
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString config.services.prometheus.port}";
              isDefault = true;
              jsonData.timeInterval = "10s";
            }
          ];
        };
      };
      settings = {
        paths.logs = "/var/log/grafana";
        server = {
          domain = "grafana.jakstys.lt";
          root_url = "http://grafana.jakstys.lt";
          enable_gzip = true;
          http_addr = "0.0.0.0";
          http_port = cfg.port;
        };
        users.auto_assign_org = true;
        users.auto_assign_org_role = "Editor";

        # https://github.com/grafana/grafana/issues/70203#issuecomment-1612823390
        auth.oauth_allow_insecure_email_lookup = true;

        "auth.generic_oauth" = {
          enabled = true;
          auto_login = true;
          client_id = "5349c113-467d-4b95-a61b-264f2d844da8";
          client_secret = "$__file{/run/grafana/oidc-secret}";
          auth_url = "https://git.jakstys.lt/login/oauth/authorize";
          api_url = "https://git.jakstys.lt/login/oauth/userinfo";
          token_url = "https://git.jakstys.lt/login/oauth/access_token";
        };
        feature_toggles.accessTokenExpirationCheck = true;
      };
    };

    systemd.services.grafana = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/oidc /run/grafana/oidc-secret";
      serviceConfig = {
        LogsDirectory = "grafana";
        RuntimeDirectory = "grafana";
        LoadCredential = [ "oidc:${cfg.oidcSecretFile}" ];
      };
    };

    mj.services.friendlyport.ports = [
      {
        subnets = [ myData.subnets.tailscale.cidr ];
        tcp = [ cfg.port ];
      }
    ];

  };

}

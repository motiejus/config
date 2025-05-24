{
  config,
  lib,
  ...
}:
let
  cfg = config.mj.services.grafana;
in
{
  options.mj.services.grafana = with lib.types; {
    enable = lib.mkEnableOption "enable grafana";
    port = lib.mkOption { type = port; };
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
        smtp = {
          enabled = true;
          from_address = "noreply@jakstys.lt";
        };
        server = {
          domain = "grafana.jakstys.lt";
          root_url = "https://grafana.jakstys.lt";
          enable_gzip = true;
          http_addr = "0.0.0.0";
          http_port = cfg.port;
        };
        users.auto_assign_org = true;
        feature_toggles.accessTokenExpirationCheck = true;
      };
    };

  };

}

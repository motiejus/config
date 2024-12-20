{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.mj.services.headscale = with lib.types; {
    enable = lib.mkEnableOption "Enable headscale";
    clientOidcPath = lib.mkOption { type = str; };
    subnetCIDR = lib.mkOption { type = str; };
  };

  config = lib.mkIf config.mj.services.headscale.enable {
    environment.systemPackages = [ pkgs.headscale ];

    networking.firewall.allowedTCPPorts = [
      3478
      8080
    ];
    networking.firewall.allowedUDPPorts = [ 3478 ];

    services = {
      headscale = {
        enable = true;
        address = "0.0.0.0";
        settings = {
          server_url = "https://vpn.jakstys.lt";
          ip_prefixes = [ config.mj.services.headscale.subnetCIDR ];
          prefixes.v4 = config.mj.services.headscale.subnetCIDR;
          log.level = "warn";
          dns = {
            nameservers.global = [
              "1.1.1.1"
              "8.8.4.4"
            ];
            magic_dns = false;
            # https://github.com/juanfont/headscale/issues/2210
            base_domain = "jakst.vpn";
          };
          oidc = {
            issuer = "https://git.jakstys.lt/";
            client_id = "e25c15ea-41ca-4bf0-9ebf-2be9f2d1ccea";
            client_secret_path = "\${CREDENTIALS_DIRECTORY}/oidc-client-secret";
          };
        };
      };

    };

    systemd.services.headscale = {
      unitConfig.StartLimitIntervalSec = "5m";

      # Allow restarts for up to a minute. A start
      # itself may take a while, thus the window of restart
      # is higher.
      unitConfig.StartLimitBurst = 50;
      serviceConfig.RestartSec = 1;
      serviceConfig.LoadCredential = [
        "oidc-client-secret:${config.mj.services.headscale.clientOidcPath}"
      ];
    };
  };
}

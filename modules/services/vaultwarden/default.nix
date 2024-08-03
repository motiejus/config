{
  config,
  lib,
  myData,
  ...
}:
let
  cfg = config.mj.services.vaultwarden;
in
{
  options.mj.services.vaultwarden = with lib.types; {
    enable = lib.mkEnableOption "Enable vautwarden";
    port = lib.mkOption { type = port; };
    secretsEnvFile = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;

      config = {
        # TODO http migration
        ROCKET_ADDRESS = "0.0.0.0";
        ROCKET_PORT = cfg.port;
        LOG_LEVEL = "warn";
        DOMAIN = "https://bitwarden.jakstys.lt";
        SIGNUPS_ALLOWED = false;
        INVITATION_ORG_NAME = "jakstys";
        PUSH_ENABLED = true;

        SMTP_HOST = "localhost";
        SMTP_PORT = 25;
        SMTP_SECURITY = "off";
        SMTP_FROM = "admin@jakstys.lt";
        SMTP_FROM_NAME = "Bitwarden at jakstys.lt";
      };
    };

    systemd.services.vaultwarden = {
      preStart = "ln -sf $CREDENTIALS_DIRECTORY/secrets.env /run/vaultwarden/secrets.env";
      serviceConfig = {
        EnvironmentFile = [ "-/run/vaultwarden/secrets.env" ];
        RuntimeDirectory = "vaultwarden";
        LoadCredential = [ "secrets.env:${cfg.secretsEnvFile}" ];
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

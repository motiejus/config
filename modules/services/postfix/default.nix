{
  config,
  lib,
  myData,
  pkgs,
  ...
}:
{
  options.mj.services.postfix = with lib.types; {
    enable = lib.mkEnableOption "Enable postfix";
    saslPasswdPath = lib.mkOption { type = path; };
  };

  config = lib.mkIf config.mj.services.postfix.enable {
    environment.systemPackages = [ pkgs.mailutils ];

    services.postfix = {
      enable = true;
      enableSmtp = true;
      networks = [
        "127.0.0.1/8"
        "[::ffff:127.0.0.0]/104"
        "[::1]/128"
        myData.subnets.tailscale.cidr
      ];
      hostname = "${config.networking.hostName}.${config.networking.domain}";
      relayHost = "smtp.sendgrid.net";
      relayPort = 587;
      mapFiles = {
        sasl_passwd = config.mj.services.postfix.saslPasswdPath;
      };
      extraConfig = ''
        smtp_sasl_auth_enable = yes
        smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
        smtp_sasl_security_options = noanonymous
        smtp_sasl_tls_security_options = noanonymous
        smtp_tls_security_level = encrypt
        header_size_limit = 4096000
      '';
    };
  };
}

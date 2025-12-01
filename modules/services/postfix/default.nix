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
      settings.main = {
        mynetworks = [
          "127.0.0.1/8"
          "[::ffff:127.0.0.0]/104"
          "[::1]/128"
          myData.subnets.tailscale.cidr
        ];
        myhostname = "relay.jakstys.lt";
        mydestination = "";
        smtpd_relay_restrictions = "permit_mynetworks, reject";
        smtpd_recipient_restrictions = "permit_mynetworks, reject_unauth_destination";
        smtp_tls_security_level = "may";
        smtpd_helo_required = "yes";
        disable_vrfy_command = "yes";
        header_size_limit = "4096000";
      };
    };
  };
}

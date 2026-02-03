{
  config,
  lib,
  ...
}:
let
  cfg = config.mj.services.ping_exporter;
in
{
  options.mj.services.ping_exporter = with lib.types; {
    enable = lib.mkEnableOption "Enable ping_exporter";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.ping = {
      enable = true;
      settings = {
        options.disableIPv6 = true;
        ping = {
          interval = "1s";
          timeout = "5s";
          history-size = 10;
        };
        targets = [
          "1.1.1.1"
          "8.8.4.4"
          "9.9.9.9"

          # NB: make sure only 1 ip address is returned for DNS domains
          "fb.com"
          "lrt.lt"
          "bite.lt"
          "github.com"

          "jakstys.lt"
          "vno2.jakstys.lt"
          "vno2-desk2.jakstys.lt"
          "fra1-c.jakstys.lt"

          "jetkvm.jakst.vpn"
          "vno3-nk.jakst.vpn"
          "sqq1-desk.jakst.vpn"
          "vno1-gdrx.jakst.vpn"
          "vno1-vj-win.jakst.vpn"
          "vno4-rutx11.jakst.vpn"
        ];
      };
    };

  };
}

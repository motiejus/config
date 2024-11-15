{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.printing;
in
{
  options.mj.services.printing = with lib.types; {
    enable = lib.mkEnableOption "Enable printing";
  };

  config = lib.mkIf cfg.enable {
    services.printing = {
      enable = true;
      drivers = [
        pkgs.samsung-unified-linux-driver_4_01_17
        (pkgs.writeTextDir "share/cups/model/HP_Color_Laser_15x_Series.ppd" (
          builtins.readFile ../../../shared/HP_Color_Laser_15x_Series.ppd
        ))
      ];
    };
  };
}

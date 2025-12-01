{
  lib,
  ...
}:
{
  imports = [ ../desktop ];

  config = {
    services.xserver = {
      desktopManager.xfce.enable = true;
    };

    services.displayManager = {
      defaultSession = lib.mkForce "xfce";
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}: {
  config = {
    services.udev.packages = [pkgs.yubikey-personalization];

    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };

    mj.base.users.passwd.motiejus.extraGroups = ["networkmanager"];

    services = {
      xserver = {
        enable = true;
        desktopManager.gnome.enable = true;
        displayManager.gdm.enable = true;
      };
    };

    networking.networkmanager.enable = true;
  };
}

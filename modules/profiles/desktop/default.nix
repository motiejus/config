{
  config,
  lib,
  pkgs,
  ...
}: {
  config = {
    services.udev.packages = [pkgs.yubikey-personalization];

    programs = {
      firefox = {
        enable = true;
        package = pkgs.firefox-devedition;
        #languagePacks = ["en" "lt" "de"];
      };
    };

    mj.base.users.passwd.motiejus.extraGroups = ["networkmanager"];

    services = {
      xserver = {
        enable = true;
        desktopManager.xfce.enable = true;
        displayManager.lightdm.enable = true;
      };

      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
    };

    security.rtkit.enable = true;

    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      pavucontrol
    ];
  };
}

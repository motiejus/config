{
  lib,
  pkgs,
  config,
  ...
}:
{
  config = {
    boot = {
      loader.systemd-boot.enable = true;
      initrd.systemd.enable = true;
      supportedFilesystems = [
        "exfat"
        "ntfs"
        "xfs"
      ];
    };

    services = {
      fwupd.enable = true;
      acpid.enable = true;
      pcscd.enable = true;

      tlp = {
        enable = lib.mkDefault true;
        settings = {
          START_CHARGE_THRESH_BAT0 = lib.mkDefault 80;
          STOP_CHARGE_THRESH_BAT0 = lib.mkDefault 87;
        };
      };
    };

    environment.systemPackages = with pkgs; [
      iw
      i7z
      acpi
      s-tui
      hdparm
      sdparm
      nvme-cli
      powertop
      efibootmgr
      alsa-utils
      tpm2-tools
      dmidecode
      stress-ng
      powerstat
      libva-utils # intel video tests
      smartmontools
      intel-gpu-tools
      config.boot.kernelPackages.cpupower
    ];
  };
}

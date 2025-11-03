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
      acpi
      i7z
      nvme-cli
      powertop
      efibootmgr
      smartmontools
      intel-gpu-tools
      tpm2-tools
      hdparm
      sdparm
      s-tui
      dmidecode
      stress-ng
      powerstat
      config.boot.kernelPackages.cpupower
    ];
  };
}

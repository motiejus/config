{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj;
in
{
  imports = [
    ../base
    ../base/sshd
    ../base/unitstatus
    ../base/users
  ];

  config = {
    i18n = {
      defaultLocale = "en_US.UTF-8";
      supportedLocales = [ "all" ];
    };

    boot = {
      # https://github.com/NixOS/nixpkgs/issues/83694#issuecomment-605657381
      kernel.sysctl = {
        "kernel.sysrq" = "438";
        "kernel.perf_event_paranoid" = "-1";
        "kernel.kptr_restrict" = "0";
      };

      kernelPackages = lib.mkDefault pkgs.linuxPackages;

      supportedFilesystems = [
        "btrfs"
        "ext4"
      ];
    };

    hardware.enableRedistributableFirmware = true;

    system.stateVersion = cfg.stateVersion;

    nix.gc.dates = "weekly";

    security = {
      sudo = {
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };
    };

    environment.systemPackages = with pkgs; [
      btdu
      lshw
      iotop
      below
      mdadm
      parted
      dhcpcd
      procps
      usbtop
      sysstat
      ethtool
      keyutils
      libkcapi
      cryptsetup
      lm_sensors
      inotify-info
      inotify-tools
      compsize
      bsdgames
      ghostty.terminfo
      ipset
      bridge-utils

      perf
      config.boot.kernelPackages.vm-tools
    ];

    programs = {
      nano.enable = false;

      tmux = {
        enable = true;
        keyMode = "vi";
        historyLimit = 1000000;
      };

      neovim = {
        enable = true;
        vimAlias = true;
        defaultEditor = true;
      };
    };
    programs.mtr.enable = true;
    programs.bcc.enable = true;

    networking.firewall.logRefusedConnections = false;

    systemd.services.dbus = {
      restartIfChanged = false;
      reloadIfChanged = lib.mkForce false;
    };

    services = {
      iperf3.enable = true;
      atd.enable = true;

      chrony = {
        enable = true;
        servers = [ "time.cloudflare.com" ];
        initstepslew.threshold = 1;
        extraConfig = ''
          makestep 1 -1
        '';
      };

      locate = {
        enable = true;
        package = pkgs.plocate;
        prunePaths = [ "/home/.btrfs" ];
      };
    };
  };
}

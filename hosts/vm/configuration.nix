{
  config,
  pkgs,
  lib,
  myData,
  ...
}: let
in {
  mj = {
    stateVersion = "23.05";
    timeZone = "UTC";
    stubPasswords = true;

    base.snapshot = {
      enable = true;
      pools = {
        var_lib = {
          mountpoint = "/var/lib";
          zfs_name = "rpool/nixos/var/lib";
        };
      };
    };
  };

  environment = {
    systemPackages = with pkgs; [
      tmux
      htop
    ];
  };

  services = {
    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
    };
  };

  networking = {
    hostName = "vm";
    domain = "jakstys.lt";
    firewall = {
      allowedTCPPorts = [53];
      allowedUDPPorts = [53];
      logRefusedConnections = false;
    };
  };

  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
      trusted-users = vm
    '';
  };
}

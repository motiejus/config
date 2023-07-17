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
  };

  users.users.vm.isSystemUser = true;
  users.users.vm.initialPassword = "test";

  environment = {
    systemPackages = with pkgs; [
      tmux
      htop
    ];
  };

  services = {
    nsd = {
      enable = true;
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

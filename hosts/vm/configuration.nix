{
  pkgs,
  myData,
  ...
}: let
in {
  mj = {
    stateVersion = "23.05";
    timeZone = "UTC";

    base.users.passwd = {
      root.initialPassword = "live";
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
    };
  };

  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
      trusted-users = vm
    '';
  };
}

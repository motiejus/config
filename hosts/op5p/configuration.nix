{myData, ...}: {
  imports = [
    ../../shared/platform/orangepi5plus.nix
  ];

  users.users = {
    motiejus = {
      isNormalUser = true;
      initialHashedPassword = "";
      openssh.authorizedKeys.keys = [myData.people_pubkeys.motiejus];
    };
    root.initialHashedPassword = "";
  };

  security = {
    pam.services.lightdm.text = ''
      auth sufficient pam_succeed_if.so user ingroup wheel
    '';
    sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };
  };

  networking = {
    hostName = "op5p";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [22];
  };

  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
      trusted-users = nixos
    '';
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["motiejus"];
    };
  };

  time.timeZone = "UTC";
  system.stateVersion = "23.11";
}

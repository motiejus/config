{...}: {
  imports = [
    ../../modules
    ../../shared/platform/orangepi5plus.nix
  ];

  mj = {
    stateVersion = "23.11";
    timeZone = "UTC";
    username = "nixos";

    base.users = {
      enable = true;
      user.initialHashedPassword = "";
      root.initialHashedPassword = "";
    };
  };

  services = {
    pcscd.enable = true;
  };

  boot.supportedFilesystems = ["bcachefs"];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      options = ["noatime"];
    };
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  networking = {
    hostName = "op5p";
    domain = "jakstys.lt";
    firewall.allowedTCPPorts = [22];
    hostId = "abefef01";
  };
}

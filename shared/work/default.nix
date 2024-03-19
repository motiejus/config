{
  config,
  pkgs,
  ...
}: {
  mj.base.users.email = "motiejus.jakstys@chronosphere.io";
  mj.base.users.user.extraGroups = ["docker"];

  environment.systemPackages =
    (with pkgs; [
      #swc
      #nodejs
      #typescript
      #concurrently
      kubectl
      kubectx
      google-cloud-sdk
    ])
    ++ (with pkgs.pkgs-unstable; [
      #turbo
    ]);

  virtualisation.docker.enable = true;

  services.clamav = {
    updater.enable = true;
    daemon = {
      enable = true;
      settings = {
        ScanMail = false;
        ScanArchive = false;
        ExcludePath = [
          "^/proc"
          "^/sys"
          "^/dev"
          "^/nix"
          "^/var"
          "^/home/.cache"
          "^/home/.go"
          "^/home/dev"
          "^/home/code"
        ];
      };
    };
  };
  # TODO remove once 24.05 is out
  systemd.services.clamav-daemon.serviceConfig = {
    StateDirectory = "clamav";
    RuntimeDirectory = "clamav";
    User = "clamav";
    Group = "clamav";
  };

  systemd.services.clamav-freshclam.serviceConfig = {
    StateDirectory = "clamav";
    User = "clamav";
    Group = "clamav";
  };

  home-manager.users.${config.mj.username} = {
    home.sessionVariables.GOPRIVATE = "github.com/chronosphereio";
    programs = {
      git.extraConfig.url."git@github.com:".insteadOf = "https://github.com";
      chromium.extensions = [
        {id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa";} # 1password
        {id = "mdkgfdijbhbcbajcdlebbodoppgnmhab";} # GoLinks
        {id = "kgjfgplpablkjnlkjmjdecgdpfankdle";} # Zoom
      ];
    };
  };
}

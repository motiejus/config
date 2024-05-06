{
  config,
  pkgs,
  ...
}: {
  mj.base.users.email = null;
  mj.base.users.user.extraGroups = ["docker"];

  environment.systemPackages =
    (with pkgs; [
      #swc
      #nodejs
      #typescript
      #concurrently
      bats
      kubectl
      kubectl-node-shell
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
    home.sessionVariables = {
      GOFLAGS = "-tags=cluster_integration";
      GOPRIVATE = "github.com/chronosphereio";
      BUILDKIT_COLORS = "run=123,20,245:error=yellow:cancel=blue:warning=white";
    };
    programs = {
      git.extraConfig = {
        url."git@github.com:".insteadOf = "https://github.com";
        user.useConfigOnly = true;
      };
      chromium.extensions = [
        {id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa";} # 1password
        {id = "mdkgfdijbhbcbajcdlebbodoppgnmhab";} # GoLinks
        {id = "kgjfgplpablkjnlkjmjdecgdpfankdle";} # Zoom
      ];
    };
  };
}

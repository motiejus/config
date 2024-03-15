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
      google-cloud-sdk
    ])
    ++ (with pkgs.pkgs-unstable; [
      #turbo
    ]);

  virtualisation.docker.enable = true;

  home-manager.users.${config.mj.username} = {
    home.sessionVariables.GOPRIVATE = "github.com/chronosphereio";
    programs.git.extraConfig.url."git@github.com:".insteadOf = "https://github.com";
  };
}

{
  config,
  pkgs,
  ...
}: {
  mj.base.users.email = "motiejus.jakstys@chronosphere.io";
  mj.base.users.user.extraGroups = ["docker"];

  environment.systemPackages =
    (with pkgs; [
      nodejs
      google-cloud-sdk
    ])
    ++ (with pkgs.nixpkgs-unstable; [
      turbo
      go_1_22
    ]);

  virtualisation.docker.enable = true;

  home-manager.users.${config.mj.username} = {
    home.sessionVariables.GOPRIVATE = "github.com/chronosphereio";
    programs.git.extraConfig.url."git@github.com:".insteadOf = "https://github.com";
  };
}

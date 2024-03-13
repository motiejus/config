{
  config,
  pkgs,
  ...
}: {
  mj.base.users.email = "motiejus.jakstys@chronosphere.io";

  environment.systemPackages = with pkgs; [
    google-cloud-sdk
  ];

  home-manager.users.${config.mj.username} = {
    home.sessionVariables.GOPRIVATE = "github.com/chronosphereio";
    programs.git.extraConfig.url."git@github.com:".insteadOf = "https://github.com";
  };
}

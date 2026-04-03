{
  config,
  lib,
  pkgs,
  ...
}:
{
  home-manager.users.${config.mj.username}.programs.ghostty = {
    enable = true;
    installVimSyntax = true;
    enableBashIntegration = true;
    settings = {
      theme = "iTerm2 Default";
      command = lib.getExe pkgs.tmuxbash;
      font-feature = [
        "-calt"
        "-liga"
        "-dlig"
      ];
    };
  };
}

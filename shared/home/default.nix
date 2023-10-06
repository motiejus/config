{
  pkgs,
  #stateVersion ? "23.05",
  ...
}: {
  home = {
    #inherit stateVersion;
    stateVersion = "23.05";

    username = "motiejus";
    homeDirectory = "/home/motiejus";
  };

  #home.packages = lib.mkIf cfg.devEnvironment [pkgs.go];

  programs.direnv.enable = true;

  programs.neovim = {
    enable = true;
    vimAlias = true;
    vimdiffAlias = true;
    defaultEditor = true;
    plugins = with pkgs.vimPlugins; [
      fugitive
    ];
    extraConfig = builtins.readFile ./vimrc;
  };

  programs.git = {
    enable = true;
    userEmail = "motiejus@jakstys.lt";
    userName = "Motiejus Jakštys";
    aliases.yolo = "commit --amend --no-edit -a";
    extraConfig = {
      rerere.enabled = true;
      pull.ff = "only";
      merge.conflictstyle = "diff3";
    };
  };

  programs.gpg = {
    enable = true;
    mutableKeys = false;
    mutableTrust = false;
    publicKeys = [
      {
        source = ./motiejus-gpg.txt;
        trust = "ultimate";
      }
    ];
  };
}

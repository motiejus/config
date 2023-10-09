{
  pkgs,
  stateVersion,
  email,
  devEnvironment,
  ...
}: {
  home = {
    inherit stateVersion;

    username = "motiejus";
    homeDirectory = "/home/motiejus";
  };

  home.packages =
    if devEnvironment
    then
      (with pkgs; [
        go

        zigpkgs."0.11.0"

        scala_2_12
        coursier
      ])
    else [];

  programs.direnv.enable = true;

  programs.neovim = {
    enable = true;
    vimAlias = true;
    vimdiffAlias = true;
    defaultEditor = true;
    plugins = with pkgs.vimPlugins;
      [
        fugitive
      ]
      ++ (
        if devEnvironment
        then [
          vim-go

          zig-vim

          nvim-metals
          plenary-nvim
        ]
        else []
      );
    extraLuaConfig = builtins.readFile ./init.lua;
  };

  programs.git = {
    enable = true;
    userEmail = email;
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

  programs.tmux = {
    enable = true;
    keyMode = "vi";
    historyLimit = 1000000;
  };
}

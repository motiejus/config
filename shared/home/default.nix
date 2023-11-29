{
  lib,
  pkgs,
  stateVersion,
  email,
  devEnvironment,
  hmOnly,
  ...
}: {
  home = {
    inherit stateVersion;

    username = "motiejus";
    homeDirectory = "/home/motiejus";
  };

  home.packages = with pkgs;
    (
      if devEnvironment
      then [
        go

        zigpkgs."0.11.0"
        sbt

        scala_2_12
        metals
        coursier
      ]
      else []
    )
    ++ (
      if hmOnly
      then [
        yt-dlp
        ncdu
        tokei
        vimv-rs
        hyperfine
      ]
      else []
    );

  programs = {
    direnv.enable = true;

    neovim = lib.mkMerge [
      {
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

              vim-vsnip
              cmp-nvim-lsp
              nvim-cmp
              nvim-metals
              plenary-nvim
            ]
            else []
          );
        extraConfig = builtins.readFile ./vimrc;
      }
      (lib.mkIf devEnvironment {
        extraLuaConfig =
          builtins.readFile
          (pkgs.substituteAll {
            src = ./dev.lua;
            javaHome = pkgs.jdk.home;
            inherit (pkgs) metals;
            inherit (pkgs) gotools;
          })
          .outPath;
      })
    ];

    git = {
      enable = true;
      userEmail = email;
      userName = "Motiejus Jakštys";
      aliases.yolo = "commit --amend --no-edit -a";
      extraConfig = {
        rerere.enabled = true;
        pull.ff = "only";
        merge.conflictstyle = "diff3";
        init.defaultBranch = "main";
      };
    };

    gpg = {
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

    tmux = {
      enable = true;
      keyMode = "vi";
      historyLimit = 1000000;
      extraConfig = ''
        bind  c  new-window      -c "#{pane_current_path}"
        bind  %  split-window -h -c "#{pane_current_path}"
        bind '"' split-window -v -c "#{pane_current_path}"
      '';
    };
  };
}

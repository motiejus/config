{
  lib,
  pkgs,
  stateVersion,
  email,
  fullDesktop,
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
      if fullDesktop
      then [
        go

        zigpkgs."0.11.0"
      ]
      else []
    )
    ++ (
      if hmOnly
      then [
        ncdu
        tokei
        scrcpy
        yt-dlp
        vimv-rs
        hyperfine
      ]
      else []
    );

  programs = {
    direnv.enable = true;

    firefox = lib.mkIf fullDesktop {
      enable = true;
      profiles = {
        xdefault = {
          isDefault = true;
          settings = {
            "browser.aboutConfig.showWarning" = false;
            "browser.contentblocking.category" = "strict";
            "browser.urlbar.showSearchSuggestionsFirst" = false;
            "layout.css.prefers-color-scheme.content-override" = 0;
            "signon.management.page.breach-alerts.enabled" = false;
            "signon.rememberSignons" = false;
          };
          extensions = with pkgs.nur.repos.rycee.firefox-addons; [
            bitwarden
            ublock-origin
            consent-o-matic
            joplin-web-clipper
            multi-account-containers
          ];
        };
      };
    };

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
            if fullDesktop
            then [
              vim-go
              zig-vim
            ]
            else []
          );
        extraConfig = builtins.readFile ./vimrc;
      }
      (lib.mkIf fullDesktop {
        extraLuaConfig =
          builtins.readFile
          (pkgs.substituteAll {
            src = ./dev.lua;
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

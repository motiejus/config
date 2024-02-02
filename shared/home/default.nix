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
    lib.mkMerge [
      (lib.mkIf fullDesktop [
        go
        zig
      ])
      (writeShellApplication {
        name = "nicer";
        text = ''
          set -e
          f=$(${coreutils}/bin/mktemp)
          trap 'rm -f "$f"' EXIT
          ${coreutils}/bin/env > "$f"
          systemd-run \
              --user \
              --same-dir \
              --slice nicer \
              --nice=19 \
              --property CPUSchedulingPolicy=idle \
              --property IOSchedulingClass=idle \
              --property IOSchedulingPriority=7 \
              --pty \
              --pipe \
              --wait \
              --collect \
              --quiet \
              --property EnvironmentFile="$f" \
              --service-type=exec \
              -- "$@"
        '';
      })
      (lib.mkIf hmOnly [
        pkgs.nixgl.nixGLIntel
        ncdu
        tokei
        scrcpy
        yt-dlp
        kubectl
        vimv-rs
        bandwhich
        hyperfine
        (runCommand "ff" {} ''
          mkdir -p $out/bin
          {
              echo '#!/bin/sh'
              echo 'exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${firefox}/bin/firefox "$@"'
          } > $out/bin/ff
          chmod a+x $out/bin/ff
        '')
      ])
    ];

  programs = {
    direnv.enable = true;

    firefox = lib.mkIf fullDesktop {
      enable = true;
      package = pkgs.firefox-bin;
      policies.DisableAppUpdate = true;
      profiles = {
        xdefault = {
          isDefault = true;
          settings = {
            "app.update.auto" = false;
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
          lib.mkMerge [
            [fugitive]
            (lib.mkIf fullDesktop [
              vim-go
              zig-vim
            ])
          ];
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

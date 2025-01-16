{
  lib,
  pkgs,
  stateVersion,
  email ? null,
  devTools,
  hmOnly,
  username,
  ...
}:
let
  homeDirectory = "/home/${username}";
in
{
  home = {
    inherit stateVersion username homeDirectory;
  };

  home.file = {
    ".parallel/will-cite".text = "";
  };

  home.sessionVariables = lib.mkIf devTools { GOPATH = "${homeDirectory}/.go"; };

  home.packages =
    with pkgs;
    lib.mkMerge [
      [ extract_url ]

      (lib.mkIf devTools [
        pkgs-unstable.delve
        pkgs-unstable.go_1_23
        pkgs-unstable.go-tools

        pkgs.zigpkgs."0.13.0"
      ])

      (lib.mkIf hmOnly [
        # pkgs by motiejus
        tmuxbash
        nicer

        ncdu
        poop
        tokei
        bloaty
        scrcpy
        yt-dlp
        vimv-rs
        ripgrep
        yamllint
        bandwhich
        hyperfine
        nix-output-monitor
      ])
    ];

  programs = lib.mkMerge [
    {
      direnv.enable = true;
      man = {
        enable = true;
        generateCaches = true;
      };

      chromium = lib.mkIf devTools {
        enable = true;
        extensions = [
          { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; } # ublock origin
          { id = "mdjildafknihdffpkfmmpnpoiajfjnjd"; } # consent-o-matic
        ];
      };
      firefox = lib.mkIf devTools {
        enable = true;
        package = pkgs.firefox-bin;
        policies.DisableAppUpdate = true;
        profiles = {
          xdefault = {
            isDefault = true;
            settings = {
              "app.update.auto" = false;
              "browser.uidensity" = 1;
              "browser.aboutConfig.showWarning" = false;
              "browser.contentblocking.category" = "strict";
              "browser.urlbar.showSearchSuggestionsFirst" = false;
              "layout.css.prefers-color-scheme.content-override" = 0;
              "signon.management.page.breach-alerts.enabled" = false;
              "signon.rememberSignons" = false;
            };
            extensions = with pkgs.nur.repos.rycee.firefox-addons; [
              bitwarden
              header-editor
              ublock-origin
              consent-o-matic
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
          plugins = lib.mkMerge [
            [ pkgs.vimPlugins.fugitive ]
            (lib.mkIf devTools [
              pkgs.vimPlugins.fzf-vim
              pkgs.vimPlugins.vim-gh-line
              pkgs.vimPlugins.nvim-lspconfig

              pkgs.pkgs-unstable.vimPlugins.vim-go
              pkgs.pkgs-unstable.vimPlugins.zig-vim
            ])
          ];
          extraConfig = builtins.readFile ./vimrc;
        }
        (lib.mkIf devTools {
          extraLuaConfig =
            builtins.readFile
              (pkgs.substituteAll {
                src = ./dev.lua;
                inherit (pkgs) ripgrep;
              }).outPath;
        })
      ];

      git = {
        enable = true;
        userEmail = email;
        userName = "Motiejus Jakštys";
        aliases.yolo = "commit --amend --no-edit -a";
        extraConfig = {
          log.date = "iso-strict-local";
          pull.ff = "only";
          core.abbrev = 12;
          pretty.fixes = "Fixes: %h (\"%s\")";
          rerere.enabled = true;
          init.defaultBranch = "main";
          merge.conflictstyle = "zdiff3";
          sendemail = {
            sendmailcmd = lib.getExe pkgs.msmtp;
            smtpserveroption = [
              "-a"
              "mj"
            ];
            confirm = "always";
            suppresscc = "self";
          };

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

      htop = {
        enable = true;
        settings = {
          header_layout = "three_25_50_25";
          column_meters_0 = "MemorySwap LoadAverage NetworkIO DiskIO";
          column_meter_modes_0 = "1 2 2 2";
          column_meters_1 = "AllCPUs4";
          column_meter_modes_1 = "1";
          column_meters_2 = "PressureStallIOSome PressureStallCPUSome PressureStallMemorySome Uptime";
          column_meter_modes_2 = "2 2 2 2";
          hide_kernel_threads = "1";
          hide_userland_threads = "1";
          show_cpu_frequency = "1";
          show_cpu_temperature = "0";
        };
      };

      tmux = {
        enable = true;
        keyMode = "vi";
        historyLimit = 1000000;
        extraConfig = ''
          bind  k  clear-history
          bind  c  new-window      -c "#{pane_current_path}"
          bind  %  split-window -h -c "#{pane_current_path}"
          bind '"' split-window -v -c "#{pane_current_path}"

          # neovim :checkhealth
          set-option -sg escape-time 10
          set-option -g default-terminal "screen-256color"
          set-option -sa terminal-features ',xterm-256color:RGB'
        '';
      };
    }
    (lib.mkIf (!hmOnly) {
      bash = {
        enable = true;
        shellAliases = {
          "l" = "echo -n ł | xclip -selection clipboard";
          "L" = "echo -n Ł | xclip -selection clipboard";
          "gp" = "${pkgs.git}/bin/git remote | ${pkgs.parallel}/bin/parallel --verbose git push";
        };
        initExtra = ''
          t() { git rev-parse --show-toplevel; }
          d() { date --utc --date=@$(echo "$1" | sed -E 's/^[^1-9]*([0-9]{10}).*/\1/') +"%F %T"; }
          source ${./gg.sh}
        '';
      };
    })
  ];
}

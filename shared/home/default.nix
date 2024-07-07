{
  lib,
  pkgs,
  stateVersion,
  email ? null,
  devTools,
  hmOnly,
  username,
  ...
}: let
  # from https://github.com/Gerg-L/demoninajar/blob/39964f198dbfa34c21f81c35370fab312b476051/homes/veritas_manjaro/nixGL.nix#L42
  mkWrapped = wrap: orig-pkg: execName:
    pkgs.makeOverridable
    (
      attrs: let
        pkg = orig-pkg.override attrs;
        outs = pkg.meta.outputsToInstall;
        paths = pkgs.lib.attrsets.attrVals outs pkg;
        nonTrivialOuts = pkgs.lib.lists.remove "out" outs;
        metaAttributes =
          pkgs.lib.attrsets.getAttrs
          (
            [
              "name"
              "pname"
              "version"
              "meta"
            ]
            ++ nonTrivialOuts
          )
          pkg;
      in
        pkgs.symlinkJoin (
          {
            inherit paths;
            nativeBuildInputs = [pkgs.makeWrapper];
            postBuild = ''
              mv $out/bin/${execName} $out/bin/.${execName}-mkWrapped-original
              makeWrapper \
                ${wrap}/bin/${wrap.name} $out/bin/${execName} \
                --add-flags $out/bin/.${execName}-mkWrapped-original
            '';
          }
          // metaAttributes
        )
    )
    {};
  glintel = mkWrapped pkgs.nixgl.nixGLIntel;
  firefox =
    if (pkgs.stdenv.hostPlatform.system == "x86_64-linux")
    then pkgs.firefox-bin
    else pkgs.firefox;
  homeDirectory = "/home/${username}";
in {
  home = {
    inherit stateVersion username homeDirectory;
  };

  home.file = {
    ".cache/evolution/.stignore".text = "*.db";
    ".parallel/will-cite".text = "";
  };

  home.sessionVariables = lib.mkIf devTools {
    GOPATH = "${homeDirectory}/.go";
  };

  home.packages = with pkgs;
    lib.mkMerge [
      [extract_url]

      (lib.mkIf devTools [
        go_1_22
        go-tools
        pkgs-unstable.zig_0_13
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

      chromium = {
        enable = true;
        extensions = [
          {id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";} # ublock origin
          {id = "mdjildafknihdffpkfmmpnpoiajfjnjd";} # consent-o-matic
        ];
      };
      firefox = lib.mkIf devTools {
        enable = true;
        # firefox doesn't need the wrapper on the personal laptop
        package =
          if hmOnly
          then (glintel firefox "firefox")
          else firefox;
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
            [pkgs.vimPlugins.fugitive]
            (lib.mkIf devTools [
              pkgs.vimPlugins.vim-go
              pkgs.vimPlugins.zig-vim
              pkgs.vimPlugins.fzf-vim
              pkgs.vimPlugins.nvim-lspconfig
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
          merge.conflictstyle = "zdiff3";
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
    (
      lib.mkIf (!hmOnly)
      {
        bash = {
          enable = true;
          shellAliases = {
            "l" = "echo -n ł | ${pkgs.xclip}/bin/xclip -selection clipboard";
            "gp" = "${pkgs.git}/bin/git remote | ${pkgs.parallel}/bin/parallel --verbose git push";
          };
          initExtra = ''
            t() { git rev-parse --show-toplevel; }
            d() { date --utc --date=@$(echo "$1" | sed -E 's/^[^1-9]*([0-9]{10}).*/\1/') +"%F %T"; }
            source ${./gg.sh}
          '';
        };
      }
    )
  ];
}

{
  lib,
  pkgs,
  stateVersion,
  email,
  fullDesktop,
  hmOnly,
  ...
}: let
  pkgNicer = pkgs.writeShellApplication {
    name = "nicer";
    text = ''
      f=$(${pkgs.coreutils}/bin/mktemp)
      trap '${pkgs.coreutils}/bin/rm -f "$f"' EXIT
      ${pkgs.coreutils}/bin/env > "$f"
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
  };

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
              makeWrapper ${wrap}/bin/${wrap.name} $out/bin/${execName} --add-flags $out/bin/.${execName}-mkWrapped-original
            '';
          }
          // metaAttributes
        )
    )
    {};
  glintel = mkWrapped pkgs.nixgl.nixGLIntel;
in {
  home = {
    inherit stateVersion;

    username = "motiejus";
    homeDirectory = "/home/motiejus";
  };

  home.packages = with pkgs;
    lib.mkMerge [
      [pkgNicer]

      (lib.mkIf fullDesktop [
        go
        zig
      ])

      (lib.mkIf hmOnly [
        ncdu
        tokei
        scrcpy
        yt-dlp
        kubectl
        vimv-rs
        bandwhich
        hyperfine
      ])
    ];

  programs = {
    direnv.enable = true;
    man = {
      enable = true;
      generateCaches = true;
    };

    firefox = lib.mkIf fullDesktop {
      enable = true;
      # firefox doesn't need the wrapper on the personal laptop
      package =
        if hmOnly
        then (glintel pkgs.firefox-bin "firefox")
        else pkgs.firefox-bin;
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
            inherit (pkgs) gotools ripgrep;
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

{
  lib,
  pkgs,
  stateVersion,
  email,
  devEnvironment,
  ...
}: let
  queryWatchman = with pkgs; let
    # TODO: this is a perl script which needs $LOCALE_ARCHIVE.
    # As of writing, I have this in my ~/.bashrc:
    # export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive
    fsmon =
      runCommand "fsmonitor-watchman"
      {
        src = "${git}/share/git-core/templates/hooks/fsmonitor-watchman.sample";
        buildInputs = [gnused];
      } ''
        sed -e 's@/usr@${perl}@' $src > $out
        chmod +x $out
      '';
  in
    writeShellScript "query-watchman" ''
      export PATH=${pkgs.watchman}/bin:$PATH
      exec ${fsmon.outPath} "$@"
    '';
in {
  home = {
    inherit stateVersion;

    username = "motiejus";
    homeDirectory = "/home/motiejus";
  };

  home.packages = with pkgs;
    [glibcLocales]
    ++ (
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
    );

  programs.direnv.enable = true;

  programs.neovim = lib.mkMerge [
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

  programs.git = {
    enable = true;
    userEmail = email;
    userName = "Motiejus Jakštys";
    aliases.yolo = "commit --amend --no-edit -a";
    extraConfig = {
      core.fsmonitor = queryWatchman.outPath;
      core.untrackedcache = true;
      rerere.enabled = true;
      pull.ff = "only";
      merge.conflictstyle = "diff3";
      init.defaultBranch = "main";
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

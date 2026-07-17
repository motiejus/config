{
  config,
  pkgs,
  ...
}:
{
  home-manager.users.${config.mj.username} = {
    imports = [ ../../../shared/home/dev.nix ];

    # The remote-control daemon only launches Codex from this fixed standalone
    # installer path. Keep that path declarative and route it to the Nixpkgs
    # binary. The standalone updater would bypass Nix, so leave its supervised
    # process alive without running the mutable install.sh updater.
    home.file.".codex/packages/standalone/current/codex".source =
      pkgs.writeShellScript "codex-standalone" ''
        if [ "$#" -eq 3 ] \
          && [ "$1" = app-server ] \
          && [ "$2" = daemon ] \
          && [ "$3" = pid-update-loop ]; then
          exec ${pkgs.coreutils}/bin/tail -f /dev/null
        fi

        exec ${pkgs.lib.getExe pkgs.pkgs-unstable.codex} "$@"
      '';
  };
  environment.systemPackages = with pkgs; [
    universal-ctags
    pkgs-unstable.go
    pkgs-unstable.delve
    pkgs-unstable.go-tools
    pkgs.zigpkgs."0.16.0"
    fq
    uv
    (fio.override { withLibnbd = false; })
    cloc
    josm
    zbar
    ninja
    shfmt
    cmake
    tokei
    caddy
    stagit
    bloaty
    skopeo
    gnuplot
    inferno
    binwalk
    undocker
    graphviz
    loccount
    hyperfine
    tesseract
    oath-toolkit
    nixpkgs-review
    git-spice
    git-filter-repo
    kaitai-struct-compiler
    pkgs.pkgs-unstable.claude-code
    pkgs.pkgs-unstable.codex

    (
      let
        py = python3.override {
          packageOverrides = _: pyPrev: {
            # ffmpeg/fish get SIGKILL in nix sandbox on darwin
            imageio-ffmpeg = pyPrev.imageio-ffmpeg.overridePythonAttrs { doCheck = false; };
            imageio = pyPrev.imageio.overridePythonAttrs { doCheck = false; };
          };
        };
      in
      py.withPackages (
        ps: with ps; [
          numpy
          pyyaml
          plotly
          jupyter
          ipython
          pymodbus
          matplotlib
        ]
      )
    )
  ];
}

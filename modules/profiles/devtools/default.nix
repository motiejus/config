{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.profiles.devtools;
in
{
  options.mj.profiles.devtools = {
    goPackages = lib.mkOption {
      type = lib.types.raw;
      default = pkgs;
      defaultText = lib.literalExpression "pkgs";
      example = lib.literalExpression "pkgs.pkgs-go";
      description = "Package set providing go and the Go dev tools (delve, staticcheck, gopls, vim-go).";
    };
  };

  config.home-manager.users.${config.mj.username} = {
    imports = [ ../../../shared/home/dev.nix ];
  };
  config.environment.systemPackages = with pkgs; [
    universal-ctags
    cfg.goPackages.go
    cfg.goPackages.delve
    cfg.goPackages.go-tools
    pkgs.zigpkgs."0.16.0"
    fq
    uv
    mdr
    (fio.override { withLibnbd = false; })
    cloc
    josm
    zbar
    ninja
    shfmt
    cmake
    tokei
    caddy
    nginx
    nodejs
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
        ps:
        with ps;
        [
          numpy
          pyyaml
          plotly
          jupyter
          ipython
          pymodbus
          matplotlib
          fonttools
        ]
        ++ fonttools.optional-dependencies.woff
      )
    )
  ];
}

{
  config,
  pkgs,
  ...
}:
{
  home-manager.users.${config.mj.username} = {
    imports = [ ../../../shared/home/dev.nix ];
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
          ipython
          pymodbus
          matplotlib
        ]
      )
    )
  ];
}

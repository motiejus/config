{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    uv
    cloc
    josm
    zbar
    ninja
    shfmt
    tokei
    bloaty
    skopeo
    inferno
    undocker
    graphviz
    loccount
    hyperfine
    tesseract
    oath-toolkit
    nixpkgs-review
    git-filter-repo
    pkgs.pkgs-unstable.claude-code

    (python3.withPackages (
      ps: with ps; [
        numpy
        pyyaml
        plotly
        ipython
        pymodbus
        matplotlib
      ]
    ))
  ];
}

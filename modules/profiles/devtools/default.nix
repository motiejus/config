{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    uv
    cloc
    josm
    zbar
    flex
    ninja
    putty
    bison
    shfmt
    tokei
    bloaty
    skopeo
    remake
    esptool
    inferno
    undocker
    graphviz
    cppcheck
    wasmtime
    loccount
    qrencode
    hyperfine
    tesseract
    postgresql
    gcc_latest
    borgbackup
    oath-toolkit
    redo-apenwarr
    git-filter-repo
    nixpkgs-review
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

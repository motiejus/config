# GNU tools under `g`-prefixed names (gsed, ggrep, gfind, gmake, ...), the way
# Homebrew installs them, so they coexist with the BSD tools on macOS.
# coreutils has native support for this (coreutils-prefixed); the rest get
# symlinks, which is enough since none of these dispatch on argv[0].
{
  lib,
  runCommand,
  gnused,
  gnugrep,
  findutils,
  diffutils,
  gnumake,
  gnutar,
  gnupatch,
  time,
  which,
  ed,
}:
let
  pkgs = [
    gnused
    gnugrep
    findutils
    diffutils
    gnumake
    gnutar
    gnupatch
    time
    which
    ed
  ];
in
runCommand "gnu-prefixed"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    meta.description = "GNU sed, grep, findutils, diffutils, make, tar, patch, time, which and ed as g-prefixed commands";
  }
  ''
    mkdir -p $out/bin $out/share/man/man1
    for p in ${lib.concatMapStringsSep " " (p: "${lib.getBin p}") pkgs}; do
      for f in "$p"/bin/*; do
        ln -s "$f" "$out/bin/g$(basename "$f")"
      done
    done
    for p in ${lib.concatMapStringsSep " " (p: "${lib.getMan p}") pkgs}; do
      for f in "$p"/share/man/man1/*; do
        [ -e "$f" ] && ln -s "$f" "$out/share/man/man1/g$(basename "$f")"
      done
    done
  ''

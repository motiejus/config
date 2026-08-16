{
  lib,
  runCommand,
  shellcheck,
  writeShellApplication,
  coreutils,
  dejavu_fonts,
  ffmpeg-headless,
  findutils,
  gawk,
  gnugrep,
  gnused,
  openssh,
  rsync,
  tzdata,
}:
let
  # The shared parts live in one store directory that the tools source at
  # startup, so the fiddly bits — the month arithmetic above all — exist once.
  # They are checked here rather than in each consumer: SC2034 is excluded
  # because a library exists precisely to define values its callers use.
  timelapseLib = runCommand "timelapse-lib" { nativeBuildInputs = [ shellcheck ]; } ''
    install -Dm444 ${./common.sh} $out/common.sh
    install -Dm444 ${./verify.sh} $out/verify.sh
    # Checked as the unit they are sourced as: verify.sh leans on common.sh for
    # log, die and $tmp. SC2034 is excluded because a library exists precisely
    # to define values that only its callers use.
    cat $out/common.sh $out/verify.sh >check.sh
    shellcheck -s bash -e SC2034 check.sh
  '';

  mkTool =
    {
      name,
      body,
      sources ? [ ],
      runtimeEnv ? null,
      inputs,
    }:
    writeShellApplication {
      inherit name runtimeEnv;
      runtimeInputs = inputs;
      # -x so shellcheck follows the sourced library and can see what it defines
      extraShellCheckFlags = [ "-x" ];
      text =
        lib.concatMapStrings (f: "source ${timelapseLib}/${f}\n") ([ "common.sh" ] ++ sources)
        + builtins.readFile body;
    };

  # No verify.sh here: checking a video is timelapse-reap's job, so that all of
  # it can be dropped one day without touching the tools that make the archive.
  videomaker = mkTool {
    name = "timelapse-videomaker";
    body = ./videomaker.sh;
    runtimeEnv = {
      TIMELAPSE_FONT = "${dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf";
      # Without this glibc reads "Europe/Vilnius" as a bare POSIX zone name with
      # no offset, and the red clock silently comes out in UTC labelled "Europe".
      TZDIR = "${tzdata}/share/zoneinfo";
    };
    inputs = [
      coreutils
      ffmpeg-headless
      findutils
      gawk
      gnugrep
    ];
  };
in
{
  timelapse-videomaker = videomaker;

  timelapse-merger = mkTool {
    name = "timelapse-merger";
    body = ./merger.sh;
    inputs = [
      coreutils
      findutils
      gawk
      gnugrep
      openssh
      rsync
    ];
  };

  timelapse-reap = mkTool {
    name = "timelapse-reap";
    body = ./reaper.sh;
    sources = [ "verify.sh" ];
    inputs = [
      coreutils
      ffmpeg-headless
      findutils
      gawk
      gnugrep
    ];
  };

  timelapse-daily = mkTool {
    name = "timelapse-daily";
    body = ./daily.sh;
    inputs = [
      coreutils
      ffmpeg-headless
      findutils
      gnugrep
      gnused
      videomaker
    ];
  };
}

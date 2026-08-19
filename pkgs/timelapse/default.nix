{
  lib,
  runCommand,
  shellcheck,
  writeShellApplication,
  coreutils,
  ffmpeg-headless,
  findutils,
  gawk,
  gnugrep,
  openssh,
  rsync,
  tzdata,
}:
let
  # The shared parts live in one store directory that the tools source at
  # startup, so the fiddly bits — the month arithmetic above all — exist once.
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
      # Without this glibc reads "Europe/Vilnius" as a bare POSIX zone name with
      # no offset, and every gap caption silently comes out in UTC.
      TZDIR = "${tzdata}/share/zoneinfo";
      # fwminex has libva-vdpau-driver installed beside mesa, and libva autodetects
      # that one: naming the driver is what keeps av1_vaapi on the Radeon whose
      # render node the script asks for by name.
      LIBVA_DRIVER_NAME = "radeonsi";
    };
    inputs = [
      coreutils
      ffmpeg-headless
      findutils
      gawk
    ];
  };
  merger = mkTool {
    name = "timelapse-merger";
    body = ./merger.sh;
    inputs = [
      coreutils
      findutils
      gnugrep
      openssh
      rsync
    ];
  };
in
{
  timelapse-videomaker = videomaker;
  timelapse-merger = merger;

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
      findutils
      merger
      videomaker
    ];
  };
}

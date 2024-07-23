/*
compressDrv compresses files in a given derivation.

Inputs:

- formats :: [String]

    List of file extensions to compress.

    Example: ["txt" "svg" "xml"]

- compressors :: [String]

    A list of compressor names to use. Each element will need to have
    an associated compressor in the same arguments (see below).

    Example: ["gz" "zstd"]

- compressor-<EXTENSION> :: String

    Map a desired extension (e.g. `gz`) to a compress program.

    The compressor program that will be executed to get the `COMPRESSOR`
    extension. The program should have a single " {}", which will be the
    replaced with the target filename.

    Compressor must:
    - read symlinks (thus --force is needed to gzip, zstd, xz).
    - keep the original file in place (--keep).

    Example compressor:

      compressor-xz = "${xz}/bin/xz --force --keep {}";

 See compressDrvWeb, which is a wrapper on top of compressDrv, for broader
 use examples.
*/
{
  lib,
  runCommand,
}: drv: {
  formats,
  compressors,
  ...
} @ args: let
  validProg = ext: prog: let
    matches = (builtins.length (builtins.split "\\{}" prog) - 1) / 2;
  in
    lib.assertMsg
    (matches == 1)
    "compressor-${ext} needs to have exactly one '{}', found ${builtins.toString matches}";
  compressorMap = lib.filterAttrs (k: _: (lib.hasPrefix "compressor-" k)) args;
  mkCmd = ext: prog:
    assert validProg ext prog; ''
      find -L $out -type f -regextype posix-extended -iregex '.*\.(${formatsPipe})' -print0 \
        | xargs -0 -P$NIX_BUILD_CORES -I{} ${prog}
    '';
  formatsPipe = builtins.concatStringsSep "|" formats;
in
  runCommand "${drv.name}-compressed" {} ''
    mkdir $out
    (cd ${drv}; find -L -type d -exec mkdir -p $out/{} ';')
    (cd ${drv}; find -L -type f -exec ln -s ${drv}/{} $out/{} ';')

    ${
      lib.concatMapStringsSep
      "\n\n"
      (ext: mkCmd ext (builtins.getAttr "compressor-${ext}" compressorMap))
      compressors
    }
  ''
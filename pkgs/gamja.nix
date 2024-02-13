{
  lib,
  stdenvNoCC,
  fetchFromSourcehut,
  buildNpmPackage,
  runCommand,
  writeText,
  brotli,
  zopfli,
  xorg,
  # https://git.sr.ht/~emersion/gamja/tree/master/doc/config-file.md
  gamjaConfig ? null,
}: let
  version = "1.0.0-beta.9";
  pkg = buildNpmPackage {
    pname = "gamja";
    inherit version;

    src = fetchFromSourcehut {
      owner = "~emersion";
      repo = "gamja";
      rev = "v${version}";
      hash = "sha256-09rCj9oMzldRrxMGH4rUnQ6wugfhfmJP3rHET5b+NC8=";
    };

    npmDepsHash = "sha256-LxShwZacCctKAfMNCUMyrSaI1hIVN80Wseq/d8WITkc=";

    installPhase = ''
        mv dist $out
      ${lib.optionalString (gamjaConfig != null) "cp ${writeText "gamja-config" (builtins.toJSON gamjaConfig)} $out/config.json"}
    '';
  };
in
  stdenvNoCC.mkDerivation {
    name = pkg.pname;
    inherit (pkg) version;
    src = pkg;
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      mv gamja-${version} $out
      runHook postInstall
    '';

    passthru = {
      data-compressed = runCommand "gamja-compressed" {} ''
        mkdir $out
        ${xorg.lndir}/bin/lndir ${pkg}/ $out/

        find $out \
            -name '*.css' -or \
            -name '*.js' -or \
            -name '*.json' -or \
            -name '*.map' -or \
            -name '*.webmanifest' -or \
            -name '*.html' | \
            tee >(xargs -n1 -P''$(nproc) ${zopfli}/bin/zopfli) | \
            xargs -n1 -P''$(nproc) ${brotli}/bin/brotli
      '';
    };

    meta = with lib; {
      description = "A simple IRC web client";
      homepage = "https://git.sr.ht/~emersion/gamja";
      license = licenses.agpl3Only;
      maintainers = with maintainers; [motiejus];
    };
  }

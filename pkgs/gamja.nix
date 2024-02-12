{
  lib,
  fetchFromSourcehut,
  buildNpmPackage,
  python3,
  writeText,
  # optional configuration attrSet, see https://git.sr.ht/~emersion/gamja#configuration-file for possible values
  gamjaConfig ? null,
}:
buildNpmPackage rec {
  pname = "gamja";
  version = "1.0.0-beta.9";

  src = fetchFromSourcehut {
    owner = "~emersion";
    repo = "gamja";
    rev = "v${version}";
    hash = "sha256-09rCj9oMzldRrxMGH4rUnQ6wugfhfmJP3rHET5b+NC8=";
  };

  npmDepsHash = "sha256-LxShwZacCctKAfMNCUMyrSaI1hIVN80Wseq/d8WITkc=";

  # without this, the aarch64-linux build fails
  nativeBuildInputs = [python3];

  installPhase = ''
    runHook preInstall

    cp -r dist $out
    ${lib.optionalString (gamjaConfig != null) "cp ${writeText "gamja-config" (builtins.toJSON gamjaConfig)} $out/config.json"}

    runHook postInstall
  '';

  meta = with lib; {
    description = "A simple IRC web client";
    homepage = "https://git.sr.ht/~emersion/gamja";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [motiejus];
  };
}

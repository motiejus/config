{
  pkgs,
  go,
  nicer,
}:
let
  go-script = pkgs.writeShellScript "go-raceless" ''
    args=("$@")
    new_args=()
    has_test=false
    found_race=false

    for arg in "''${args[@]}"; do
        if [[ "$arg" == "test" ]]; then
            has_test=true
        fi
    done

    if [[ "$has_test" == "true" ]]; then
        for arg in "''${args[@]}"; do
            if [[ "$arg" != "-race" ]]; then
                new_args+=("$arg")
            else
                found_race=true
            fi
        done

        if [[ "$found_race" == "true" ]]; then
            exec ${nicer}/bin/nicer ${go}/bin/go "''${new_args[@]}"
        fi
    fi

    exec ${nicer}/bin/nicer ${go}/bin/go "$@"
  '';

  preservedAttrs = pkgs.lib.attrsets.getAttrs [
    "CGO_ENABLED"
    "GOARCH"
    "GOOS"
    "meta"
  ] go;
in
pkgs.symlinkJoin (
  {
    name = "go-raceless";
    paths = [ go ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm $out/bin/go
      cp ${go-script} $out/bin/go
      chmod +x $out/bin/go
    '';
  }
  // preservedAttrs
  // {
    passthru = go.passthru or { };
  }
)

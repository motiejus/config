{ pkgs, go }:
let
  go-wrapper = pkgs.writeShellApplication {
    name = "go";
    text = ''
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
              exec "$REAL_GO" "''${new_args[@]}"
          fi
      fi

      exec "$REAL_GO" "$@"
    '';
  };

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

      makeWrapper ${go-wrapper}/bin/go $out/bin/go \
        --set REAL_GO ${go}/bin/go
    '';
  }
  // preservedAttrs
  // {
    passthru = go.passthru or { };
  }
)

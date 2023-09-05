{
  stdenv,
  pkgs,
  prometheus-snmp-exporter,
}:
stdenv.mkDerivation {
  name = "snmp-yaml";
  inherit (prometheus-snmp-exporter) version src;

  buildInputs = [prometheus-snmp-exporter];

  buildPhase = ''
    mkdir -p $out
    set -x
    cd $src/generator
    ${prometheus-snmp-exporter}/bin/generator generate \
        --output-path=$out/snmp.yml
  '';
}

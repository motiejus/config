{
  stdenv,
  pkgs,
}:
stdenv.mkDerivation {
  name = "snmp-yaml";

  buildInputs = [pkgs.prometheus-snmp-exporter];

  installPhase = ''
    mkdir -p $out
    ${pkgs.prometheus-snmp-exporter}/bin/generator generate \
        ${pkgs.prometheus-snmp-exporter}/generator/generator.yaml \
        --output-path=$out/snmp.yml
  '';
}

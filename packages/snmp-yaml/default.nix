{
  stdenv,
  pkgs,
}:
stdenv.mkDerivation {
  pname = "snmp-yaml";

  buildInputs = [pkgs.snmp-exporter];

  installPhase = ''
    mkdir -p $out
    ${pkgs.snmp-exporter}/bin/generator generate \
        ${pkgs.snmp-exporter}/generator/generator.yaml \
        --output-path=$out/snmp.yml
  '';
}

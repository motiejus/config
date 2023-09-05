How to upgrade snmp.yml

1. Extend generator.yml from the upstream generator.yml in snmp_exporter/generator/generator.yml
2. Generate snmp.yml:

    snmp_exporter/generator$ make mibs
    packages/snmp-yaml $ MIBDIRS=$HOME/code/snmp_exporter/generator/mibs /nix/store/wmymig1r9jfiaffbdpv1lyaj32rydbzc-snmp_exporter-0.21.0/bin/generator generate


{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./borgstor
    ./deployerbot
    ./friendlyport
    ./gitea
    ./headscale
    ./matrix-synapse
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./snmp_exporter
    ./syncthing
    ./zfsunlock
  ];
}

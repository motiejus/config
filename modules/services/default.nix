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
    ./jakstpub
    ./matrix-synapse
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./snmp_exporter
    ./sshguard
    ./syncthing
    ./tailscale
    ./zfsunlock
  ];
}

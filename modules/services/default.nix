{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./deployerbot
    ./friendlyport
    ./gitea
    ./headscale
    ./matrix-synapse
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

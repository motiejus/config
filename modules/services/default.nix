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
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

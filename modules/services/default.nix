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
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

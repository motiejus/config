{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./deployerbot
    ./friendlyport
    ./node_exporter
    ./nsd-acme
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

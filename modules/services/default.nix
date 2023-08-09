{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./deployerbot
    ./friendlyport
    ./nsd-acme
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

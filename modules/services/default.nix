{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./deployerbot
    ./friendlyport
    ./postfix
    ./syncthing
    ./zfsunlock
  ];
}

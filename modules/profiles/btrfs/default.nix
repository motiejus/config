{ pkgs, ... }:
{
  boot.supportedFilesystems = [ "btrfs" ];

  environment.systemPackages = [ pkgs.btrfs-auto-snapshot ];
}

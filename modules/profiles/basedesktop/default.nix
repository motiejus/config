{ config, lib, pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.scrcpy
    pkgs.yt-dlp
    (if pkgs.stdenv.isDarwin then pkgs.vlc-bin else pkgs.vlc)
  ];

  home-manager.users.${config.mj.username} = {
    imports = [ ../../../shared/home/gui.nix ];
  };
}

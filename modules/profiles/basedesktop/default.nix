{ config, lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    scrcpy
    yt-dlp
    ffmpeg
    pandoc
    imagemagick
    ghostscript
    poppler-utils
    magic-wormhole
    age-plugin-yubikey
    (if stdenv.isDarwin then vlc-bin else vlc)
  ];

  home-manager.users.${config.mj.username} = {
    imports = [ ../../../shared/home/gui.nix ];
  };
}

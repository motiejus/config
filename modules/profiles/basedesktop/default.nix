{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    scrcpy
    yt-dlp
    ffmpeg
    pandoc
    imagemagick
    poppler-utils
    magic-wormhole
    nix-prefetch-git
    age-plugin-yubikey
    (if stdenv.isDarwin then vlc-bin else vlc)
  ];
}

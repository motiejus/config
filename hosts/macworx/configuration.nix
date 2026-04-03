{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;
  environment.systemPackages = with pkgs; [
    ripgrep
    ghostty-bin
  ];
}

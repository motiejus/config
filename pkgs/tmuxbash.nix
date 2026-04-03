{ tmux, bash, writeShellApplication, ... }:
writeShellApplication {
  name = "tmuxbash";
  text = ''
    ${tmux}/bin/tmux
    exec ${bash}/bin/bash
  '';
}

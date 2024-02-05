{
  tmux,
  bash,
  writeShellApplication,
  ...
}:
writeShellApplication {
  name = "tmuxbash";
  text = ''
    ${tmux}/bin/tmux
    ${bash}/bin/bash
  '';
}

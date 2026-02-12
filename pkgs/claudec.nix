{
  writeShellApplication,
  pkgs,
  ...
}:
writeShellApplication {
  name = "claudec";
  text = ''
    ${pkgs.bubblewrap}/bin/bwrap --proc /proc \
      --dev /dev \
      --tmpfs /tmp \
      --tmpfs "$HOME" \
      --symlink "$(readlink -f /run/current-system)" /run/current-system \
      --symlink "$(readlink -f /etc/hosts)" /etc/hosts \
      --symlink "$(readlink -f /etc/static)" /etc/static \
      --symlink "$(readlink -f /etc/static/ssl)" /etc/ssl \
      --symlink "$(readlink -f /usr/bin/env)" /usr/bin/env \
      --symlink "$(readlink -f "$HOME/.nix-profile")" "$HOME/.nix-profile" \
      --ro-bind /nix/store /nix/store \
      --ro-bind /nix/var/nix/db /nix/var/nix/db \
      --ro-bind /run/wrappers /run/wrappers \
      --ro-bind /etc/resolv.conf /etc/resolv.conf \
      --ro-bind /etc/passwd /etc/passwd \
      --ro-bind /etc/group /etc/group \
      --ro-bind /etc/nix /etc/nix \
      --bind "$HOME/.claude.json" "$HOME/.claude.json" \
      --bind "$HOME/.cache/zig" "$HOME/.cache/zig" \
      --bind "$HOME/.claude" "$HOME/.claude" \
      --bind "$HOME/.config/nvim" "$HOME/.config/nvim" \
      --bind "$HOME/code" "$HOME/code" \
      --setenv HOME "$HOME" \
      --setenv USER motiejus \
      --die-with-parent \
      --chdir "$HOME/code" \
      --unshare-user \
      --uid 1001 \
      --gid 1001 -- \
        claude --dangerously-skip-permissions "$@"
  '';
}

{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Seeded into ~/.claude/settings.json only when the file does not yet exist,
  # so Claude Code keeps write access to it at runtime (permission grants,
  # /config edits, plugin toggles). To re-seed, delete the file and re-switch.
  claudeSettings = {
    permissions.allow = [ "Edit(.cache/zig/**)" ];
    tui = "default";
    skipDangerousModePermissionPrompt = true;
    attribution = {
      commit = "Generated with an LLM";
      sessionUrl = false;
    };
  };
  claudeSettingsFile = pkgs.writeText "claude-settings.json" (builtins.toJSON claudeSettings);
in
{
  home.sessionVariables = {
    GOPATH = "${config.home.homeDirectory}/.go";
  };

  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "$HOME/.claude/settings.json" ]; then
      run mkdir -p "$HOME/.claude"
      run cp ${claudeSettingsFile} "$HOME/.claude/settings.json"
      run chmod 644 "$HOME/.claude/settings.json"
    fi
  '';

  programs.neovim = {
    plugins = [
      pkgs.vimPlugins.fzf-vim
      pkgs.vimPlugins.typst-vim
      pkgs.vimPlugins.vim-gh-line
      pkgs.vimPlugins.vim-gutentags
      pkgs.vimPlugins.nvim-lspconfig

      pkgs.pkgs-unstable.vimPlugins.vim-go
      pkgs.pkgs-unstable.vimPlugins.zig-vim
    ];
    initLua =
      builtins.readFile
        (pkgs.replaceVars ./dev.lua {
          inherit (pkgs) ripgrep;
          inherit (pkgs.pkgs-unstable) gopls;
        }).outPath;
  };
}

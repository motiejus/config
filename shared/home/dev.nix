{ pkgs, config, ... }:
{
  home.sessionVariables = {
    GOPATH = "${config.home.homeDirectory}/.go";
  };

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
    extraLuaConfig =
      builtins.readFile
        (pkgs.replaceVars ./dev.lua {
          inherit (pkgs) ripgrep;
          inherit (pkgs.pkgs-unstable) gopls;
        }).outPath;
  };
}

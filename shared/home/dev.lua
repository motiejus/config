vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
    "au FileType go let g:go_fmt_command = "@gotools@/bin/goimports"
]], false)


-- trying https://github.com/neovim/nvim-lspconfig/issues/888
local lspconfig = require("lspconfig")
lspconfig.gopls.setup({
  cmd = {"@gopls@/bin/gopls"},
  settings = {
    gopls = {
      buildFlags = {"-tags=integration"},
    },
  },
})

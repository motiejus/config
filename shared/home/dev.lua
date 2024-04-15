vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
    au FileType go let g:go_fmt_command = "@gotools@/bin/goimports"
]], false)


-- trying https://github.com/neovim/nvim-lspconfig/issues/888
local lspconfig = require("lspconfig")
lspconfig.gopls.setup({
  settings = {
    gopls = {
      --env = {GOFLAGS="-tags=cluster_integration"}
      --buildFlags =  {"-tags=big integration cluster_integration"},
      analyses = {
        unusedparams = true,
      },
      staticcheck = true,
      gofumpt = true,
    },
  },
})

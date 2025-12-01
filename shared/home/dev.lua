-- Updated to use vim.lsp.config (nvim 0.11+) instead of deprecated lspconfig
vim.lsp.config.clangd = {
    cmd = { "nicer", "clangd" }
}

vim.lsp.config.gopls = {
    cmd = { "nicer", "@gopls@/bin/gopls" }
}

vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
]], false)

vim.filetype.add({extension = {star = 'python'}})

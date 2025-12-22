-- Updated to use vim.lsp.config (nvim 0.11+) instead of deprecated lspconfig
vim.lsp.config.clangd = {
    cmd = { "nicer", "clangd" },
    filetypes = { "c", "cpp" },
    root_markers = { "compile_commands.json", ".clangd", ".git" }
}

vim.lsp.config.gopls = {
    cmd = { "nicer", "@gopls@/bin/gopls" },
    filetypes = { "go" },
    root_markers = { "go.mod", ".git" }
}

-- Enable the LSP servers
vim.lsp.enable({ "clangd", "gopls" })

vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
]], false)

vim.filetype.add({extension = {star = 'python'}})

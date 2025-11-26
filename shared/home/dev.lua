require'lspconfig'.clangd.setup{
    cmd = { "nicer", "clangd" }
}

require'lspconfig'.gopls.setup{
    cmd = { "nicer", "gopls" }
}

vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
]], false)

vim.filetype.add({extension = {star = 'python'}})

vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
    "au FileType go let g:go_fmt_command = "@gotools@/bin/goimports"
]], false)

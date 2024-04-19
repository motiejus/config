vim.api.nvim_exec([[
    set grepprg=@ripgrep@/bin/rg\ --vimgrep grepformat^=%f:%l:%c:%m
]], false)

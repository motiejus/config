vim.api.nvim_exec([[
    au FileType go nnoremap <buffer> <C-]> :GoDef<CR>
    au FileType go let g:go_template_autocreate = 0
    au FileType go let g:go_fmt_command = "@gotools@/bin/goimports"
]], false)

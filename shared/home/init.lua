vim.api.nvim_exec([[
    syntax on
    filetype plugin indent on
    set et ts=4 sw=4 sts=4 nu hlsearch ruler ignorecase smartcase nomodeline bg=dark incsearch
    set path=**/* grepprg=rg\ --vimgrep grepformat^=%f:%l:%c:%m backspace=2 nojs
    set laststatus=1
    nnoremap <Leader>\ gqj
    command OLD :enew | setl buftype=nofile | 0put =v:oldfiles | nnoremap <buffer> <CR> :e <C-r>=getline('.')<CR><CR>

    let g:gutentags_enabled = 0
    let g:gutentags_generate_on_new = 0
    let g:gutentags_cache_dir = '~/.vim/ctags'
    let b:gutentags_file_list_command = 'git ls-files'

    call matchadd('ColorColumn', '\%81v', 100)
    " thanks to drew de vault's vimrc, except swearing
    set mouse=
    set backupdir=~/.cache directory=~/.cache
    "nnoremap Q :grep <cword><CR>
    nmap gs :grep <cursor><CR>

    " bits from vim-sensible
    set autoindent smarttab nrformats-=octal
    nnoremap <silent> <C-L> :nohlsearch<C-R>=has('diff')?'<Bar>diffupdate':''<CR><CR><C-L>
    set wildmenu sidescrolloff=5 display+=lastline encoding=utf-8
    set formatoptions+=j history=1000 tabpagemax=50 sessionoptions-=options

    " so Gdiff and vimdiff output are somewhat readable
    if &diff
        syntax off
    endif

    if has("patch-8.1-0360")
      set diffopt+=algorithm:patience
    endif

    " html
    au FileType html,gohtmltmpl setlocal ts=2 sw=2 sts=2

    " ruby
    au BufRead,BufNewFile Vagrantfile setfiletype ruby

    " puppet
    au BufRead,BufNewFile *.j2 setfiletype django

    " avro
    au BufRead,BufNewFile *.avsc setfiletype json
    au BufRead,BufNewFile *.avsc setlocal ts=2 sw=2 sts=2

    " redo
    au BufRead,BufNewFile *.do setfiletype sh

    " go
    au FileType go setlocal noet
    au FileType go nnoremap <buffer> <C-]> :GoDef<CR>
    au FileType go let g:go_template_autocreate = 0
    au FileType go let g:go_fmt_command = "goimports"

    " strace
    au FileType strace setlocal nonu

    " yaml
    au FileType yaml setlocal ts=2 sw=2 sts=2

    " sql
    au FileType sql setlocal formatprg=pg_format\ -
    au FileType sql setlocal ts=2 sw=2 sts=2
    let g:loaded_sql_completion = 0
    let g:omni_sql_no_default_maps = 1

    " mail
    autocmd BufRead,BufNewFile *mutt-* setfiletype mail

    " TeX
    au FileType tex setlocal spell spelllang=en_us ts=2 sw=2 sts=2
]], false)

local api = vim.api
local cmd = vim.cmd
local map = vim.keymap.set

----------------------------------
-- OPTIONS -----------------------
----------------------------------
-- global
vim.opt_global.completeopt = { "menuone", "noinsert", "noselect" }
vim.opt_global.shortmess:remove("F")

-- LSP mappings
map("n", "gD",  vim.lsp.buf.definition)
map("n", "K",  vim.lsp.buf.hover)
map("n", "gi", vim.lsp.buf.implementation)
map("n", "gr", vim.lsp.buf.references)
map("n", "gds", vim.lsp.buf.document_symbol)
map("n", "gws", vim.lsp.buf.workspace_symbol)
map("n", "<leader>cl", vim.lsp.codelens.run)
map("n", "<leader>sh", vim.lsp.buf.signature_help)
map("n", "<leader>rn", vim.lsp.buf.rename)
map("n", "<leader>f", vim.lsp.buf.format)
map("n", "<leader>ca", vim.lsp.buf.code_action)

map("n", "<leader>ws", function()
  require("metals").hover_worksheet()
end)

-- all workspace diagnostics
map("n", "<leader>aa", vim.diagnostic.setqflist)

-- all workspace errors
map("n", "<leader>ae", function()
  vim.diagnostic.setqflist({ severity = "E" })
end)

-- all workspace warnings
map("n", "<leader>aw", function()
  vim.diagnostic.setqflist({ severity = "W" })
end)

-- buffer diagnostics only
map("n", "<leader>d", vim.diagnostic.setloclist)

map("n", "[c", function()
  vim.diagnostic.goto_prev({ wrap = false })
end)

map("n", "]c", function()
  vim.diagnostic.goto_next({ wrap = false })
end)

-- completion related settings
-- This is similiar to what I use
local cmp = require("cmp")
cmp.setup({
  sources = {
    { name = "nvim_lsp" },
    { name = "vsnip" },
  },
  snippet = {
    expand = function(args)
      -- Comes from vsnip
      vim.fn["vsnip#anonymous"](args.body)
    end,
  },
  mapping = cmp.mapping.preset.insert({
    -- None of this made sense to me when first looking into this since there
    -- is no vim docs, but you can't have select = true here _unless_ you are
    -- also using the snippet stuff. So keep in mind that if you remove
    -- snippets you need to remove this select
    ["<CR>"] = cmp.mapping.confirm({ select = true }),
    -- I use tabs... some say you should stick to ins-completion but this is just here as an example
    ["<Tab>"] = function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      else
        fallback()
      end
    end,
    ["<S-Tab>"] = function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      else
        fallback()
      end
    end,
  }),
})



----------------------------------
-- LSP Setup ---------------------
----------------------------------
local metals_config = require("metals").bare_config()

-- Example of settings
metals_config.settings = {
  showImplicitArguments = true,
  excludedPackages = { "akka.actor.typed.javadsl", "com.github.swagger.akka.javadsl" },
  metalsBinaryPath = "@metals@/bin/metals",
}

-- *READ THIS*
-- I *highly* recommend setting statusBarProvider to true, however if you do,
-- you *have* to have a setting to display this in your statusline or else
-- you'll not see any messages from metals. There is more info in the help
-- docs about this
 metals_config.init_options.statusBarProvider = "on"

-- Example if you are using cmp how to make sure the correct capabilities for snippets are set
metals_config.capabilities = require("cmp_nvim_lsp").default_capabilities()

-- Autocmd that will actually be in charging of starting the whole thing
local nvim_metals_group = api.nvim_create_augroup("nvim-metals", { clear = true })
api.nvim_create_autocmd("FileType", {
  -- NOTE: You may or may not want java included here. You will need it if you
  -- want basic Java support but it may also conflict if you are using
  -- something like nvim-jdtls which also works on a java filetype autocmd.
  pattern = { "scala", "sbt", "java" },
  callback = function()
    require("metals").initialize_or_attach(metals_config)
  end,
  group = nvim_metals_group,
})

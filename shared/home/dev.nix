{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Seeded into ~/.claude/settings.json only when the file does not yet exist,
  # so Claude Code keeps write access to it at runtime (permission grants,
  # /config edits, plugin toggles). To re-seed, delete the file and re-switch.
  claudeSettings = {
    permissions.allow = [ "Edit(.cache/zig/**)" ];
    tui = "default";
    skipDangerousModePermissionPrompt = true;
    attribution = {
      commit = "Generated with an LLM";
      sessionUrl = false;
    };
  };
  claudeSettingsFile = pkgs.writeText "claude-settings.json" (builtins.toJSON claudeSettings);

  # Shared cgroup v2 memory pool for agent-sandbox commands. All uid-1001
  # agents route their build/test/tool invocations (via ~/code/.mem-limit-run)
  # into ONE pool cgroup, so the kernel bounds their AGGREGATE resident memory.
  # The agent sessions themselves (claude/codex/node) stay OUT of the pool.
  #
  # NOTE: restarting this service (incl. a home-manager switch that changes the
  # unit) SIGKILLs every process in the pool -- i.e. all in-flight builds of all
  # agents -- and recreates the cgroup, leaving already-running sandboxes bound
  # to a stale (deleted) cgroup dir until they are relaunched. Avoid gratuitous
  # changes here while builds are running.
  memPoolMaxBytes = 16 * 1024 * 1024 * 1024; # hard RESIDENT cap for the whole pool
  memPoolSwapBytes = 8 * 1024 * 1024 * 1024; # bounded swap the pool may use past the RSS cap
  memPoolScript = pkgs.writeShellScript "agent-mem-pool-setup" ''
    set -eu

    # Started with Delegate=yes, so systemd created a cgroup for this service with
    # the memory controller delegated and cgroup.subtree_control/procs owned by
    # the user. Resolve it from our own /proc entry (0::<path>).
    cg="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"

    # Move our (main) process into a leaf. This does double duty: (1) a controller
    # can only be enabled in a cgroup with no member processes, and (2) this
    # process stays alive here as `sleep infinity`, which is what KEEPS the
    # delegated subtree (incl. the pool) from being trimmed by systemd. A oneshot
    # service leaves the cgroup empty on exit and systemd then recursively removes
    # the empty pool/keep dirs -- hence a long-lived Type=simple service instead.
    # The keeper lives OUTSIDE the pool, so a pool OOM can never kill it.
    mkdir -p "$cg/keep"
    echo $$ > "$cg/keep/cgroup.procs"

    # Make the memory controller available to children, then create the pool.
    echo +memory > "$cg/cgroup.subtree_control"
    mkdir -p "$cg/pool"

    # Cap RESIDENT memory of the whole pool (memory.max) and allow a BOUNDED
    # amount of swap past it (memory.swap.max), so brief overshoots spill to swap
    # instead of an instant kill -- without letting the pool consume all system
    # swap. No memory.high: on a box whose swap can be full, the high..max band
    # only stalls; going straight to a clean memory.max OOM yields an
    # attributable "cap death is a finding" kill (AGENTS.md §7).
    echo ${toString memPoolMaxBytes}  > "$cg/pool/memory.max"
    echo ${toString memPoolSwapBytes} > "$cg/pool/memory.swap.max"

    # Publish the resolved pool path so each bwrap launcher can bind it.
    mkdir -p "$XDG_RUNTIME_DIR"
    printf '%s\n' "$cg/pool" > "$XDG_RUNTIME_DIR/mem-pool.cgroup"

    # Stay alive so the delegated cgroup (and thus the pool) persists.
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
{
  # Provision the shared agent memory pool once per user session.
  systemd.user.services.agent-mem-pool = {
    Unit = {
      Description = "Shared cgroup v2 memory pool for agent-sandbox commands";
      Documentation = [ "file://${config.home.homeDirectory}/code/AGENTS.md" ];
    };
    Service = {
      # Long-lived (not oneshot): the ExecStart parks a `sleep infinity` in the
      # delegated subtree so systemd does not trim the pool cgroup. See script.
      Type = "simple";
      Delegate = true;
      MemoryAccounting = true;
      ExecStart = "${memPoolScript}";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "default.target" ];
  };

  home.sessionVariables = {
    GOPATH = "${config.home.homeDirectory}/.go";
  };

  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "$HOME/.claude/settings.json" ]; then
      run mkdir -p "$HOME/.claude"
      run cp ${claudeSettingsFile} "$HOME/.claude/settings.json"
      run chmod 644 "$HOME/.claude/settings.json"
    fi
  '';

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
    initLua =
      builtins.readFile
        (pkgs.replaceVars ./dev.lua {
          inherit (pkgs) ripgrep;
          inherit (pkgs.pkgs-unstable) gopls;
        }).outPath;
  };
}

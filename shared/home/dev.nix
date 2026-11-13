{
  pkgs,
  lib,
  config,
  osConfig,
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

  # Shared cgroup v2 memory pool: each agent sandbox gets a group in it whose
  # leaves run its commands, under one aggregate memory cap (AGENTS.md §7).
  # The pool lives in agent-mem-pool.slice, not the keeper's cgroup, so it
  # survives keeper restarts; changing the slice unit means relaunching agents.
  memPoolMaxBytes = 16 * 1024 * 1024 * 1024; # hard RESIDENT cap for the whole pool
  memPoolSwapBytes = 8 * 1024 * 1024 * 1024; # bounded swap the pool may use past the RSS cap
  memPoolScript = pkgs.writeShellScript "agent-mem-pool-setup" ''
    set -eu

    # The pool is a sibling of this service under the slice, so a keeper
    # restart keeps its inode (and every sandbox bind mount of it) live.
    cg="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
    slice="$(dirname "$cg")"
    for c in memory cpuset cpu; do echo +$c > "$slice/cgroup.subtree_control" 2>/dev/null || true; done
    mkdir -p "$slice/pool"

    # Separate writes: a combined one is atomic, and cpuset may be missing until
    # user@.service delegates it (modules/profiles/coding-agent). cpu weighs
    # sessions equally; by convention batch jobs pin CPUs 0-11, timing runs 12-15.
    echo +memory +pids > "$slice/pool/cgroup.subtree_control" 2>/dev/null || true
    echo +cpuset > "$slice/pool/cgroup.subtree_control" 2>/dev/null || true
    echo +cpu > "$slice/pool/cgroup.subtree_control" ||
      echo "agent-mem-pool: WARNING -- cannot enable cpu for the pool: agents compete per process, not per group." >&2

    # Hard resident cap plus bounded swap; no memory.high, which only stalls
    # when swap is full. A cap kill is a finding (AGENTS.md §7).
    echo ${toString memPoolMaxBytes}  > "$slice/pool/memory.max"
    echo ${toString memPoolSwapBytes} > "$slice/pool/memory.swap.max"

    # Publish the resolved pool path for the sandbox launchers.
    printf '%s\n' "$slice/pool" > "$XDG_RUNTIME_DIR/mem-pool.cgroup"

    # Keep the slice active; every minute remove the groups of sessions whose
    # pid (the name suffix) is gone. rmdir only removes empty cgroups.
    while :; do
      for g in "$slice"/pool/*/; do
        pid=''${g%/}
        pid=''${pid##*-}
        [ -e "/proc/$pid" ] || rmdir "$g"*/ "$g" 2>/dev/null || true
      done
      ${pkgs.coreutils}/bin/sleep 60
    done
  '';
in
{
  # Persistent home for the pool: delegated so the keeper can create and size
  # it; its cgroup outlives restarts of the services inside it.
  systemd.user = {
    slices."agent-mem-pool" = {
      Unit = {
        Description = "Persistent cgroup v2 memory pool for agent-sandbox commands";
        Documentation = [ "file://${config.home.homeDirectory}/code/AGENTS.md" ];
      };
      Slice = {
        Delegate = true;
        MemoryAccounting = true;
      };
    };

    # nice and SCHED_IDLE only count inside a cpu group, so with cpu enabled at
    # this level pkgs/nicer.nix needs an idle slice to stay behind the agents.
    slices.nicer = {
      Unit.Description = "Idle-priority jobs started by nicer";
      Slice.CPUWeight = "idle";
    };

    # Keeper: provisions the pool under the slice, keeps the slice active and
    # sweeps the groups of ended sessions.
    services.agent-mem-pool = {
      Unit = {
        Description = "Shared cgroup v2 memory pool for agent-sandbox commands";
        Documentation = [ "file://${config.home.homeDirectory}/code/AGENTS.md" ];
      };
      Service = {
        # Long-lived (not oneshot) so the slice keeps an active unit. See script.
        Type = "simple";
        Slice = "agent-mem-pool.slice";
        MemoryAccounting = true;
        # Slices cannot delegate: delegating cpuset and cpu to this service makes
        # the user manager enable them in the slice, so they reach the pool.
        Delegate = "cpuset cpu";
        ExecStart = "${memPoolScript}";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "default.target" ];
    };
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

      osConfig.mj.profiles.devtools.goPackages.vimPlugins.vim-go
      pkgs.pkgs-unstable.vimPlugins.zig-vim
    ];
    initLua =
      builtins.readFile
        (pkgs.replaceVars ./dev.lua {
          inherit (pkgs) ripgrep;
          inherit (osConfig.mj.profiles.devtools.goPackages) gopls;
        }).outPath;
  };
}

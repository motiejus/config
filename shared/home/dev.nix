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
  # The pool lives in a PERSISTENT slice (agent-mem-pool.slice), NOT inside this
  # keeper service's own cgroup. That is deliberate: systemd destroys a service's
  # cgroup subtree on every restart, but leaves the slice -- and thus the pool
  # cgroup and every build parked in it -- intact. So restarting this keeper
  # (on-failure, or a home-manager switch that changes only the keeper script) no
  # longer SIGKILLs in-flight builds, and no longer strands already-running
  # sandboxes on a deleted cgroup inode (a bind mount pins an inode; recreating
  # the leaf under the service was what made it dangle). The ONE remaining
  # destructive case is changing the SLICE unit itself (or logout/reboot): after
  # such a change, relaunch the agent sandboxes once so they re-bind the freshly
  # created pool.
  memPoolMaxBytes = 16 * 1024 * 1024 * 1024; # hard RESIDENT cap for the whole pool
  memPoolSwapBytes = 8 * 1024 * 1024 * 1024; # bounded swap the pool may use past the RSS cap
  memPoolScript = pkgs.writeShellScript "agent-mem-pool-setup" ''
    set -eu

    # This keeper runs inside the delegated slice agent-mem-pool.slice, in its own
    # service cgroup (.../agent-mem-pool.slice/agent-mem-pool.service). Resolve
    # that from our /proc entry (0::<path>), then step UP to the slice: the pool
    # is created at the slice level so it outlives restarts of this service.
    cg="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
    slice="$(dirname "$cg")"

    # Make the memory controller available to the slice's children so the pool
    # leaf gets memory.*. Permitted because the slice has no member processes of
    # its own (this keeper lives in a child cgroup). systemd also enables this
    # when it sets up the delegated+accounted slice, so tolerate it being done
    # already; the pool/memory.max write below is the real check (set -eu).
    # cpuset likewise, via this service's Delegate= -- the guarded write also
    # covers the window before user@.service delegates cpuset at all.
    echo +memory > "$slice/cgroup.subtree_control" 2>/dev/null || true
    echo +cpuset > "$slice/cgroup.subtree_control" 2>/dev/null || true

    # Create the shared pool as a SIBLING of this service, directly under the
    # slice -- NOT inside this service's own cgroup. This is the whole fix: a
    # restart of this service recreates only .../agent-mem-pool.service and leaves
    # .../pool untouched (mkdir -p preserves the existing inode), so builds parked
    # in it survive and sandbox bind mounts stay live.
    mkdir -p "$slice/pool"

    # Delegate controllers to the per-job leaves (mem-limit-run requires a
    # named leaf): memory+pids for caps and attribution, cpuset so a leaf can
    # pin CPUs -- convention: CPUs 12-15 are RESERVED for timing-sensitive
    # runs, heavy batch jobs pin themselves to 0-11. Separate writes because a
    # combined write is atomic: cpuset missing (user manager started before
    # user@.service delegated it, see modules/profiles/coding-agent) must not
    # block memory+pids. cgroup v2 cpuset needs no parent seeding -- an empty
    # cpuset.cpus inherits the parent's effective set.
    echo +memory +pids > "$slice/pool/cgroup.subtree_control" 2>/dev/null || true
    echo +cpuset > "$slice/pool/cgroup.subtree_control" 2>/dev/null || true

    # Cap RESIDENT memory of the whole pool (memory.max) and allow a BOUNDED
    # amount of swap past it (memory.swap.max), so brief overshoots spill to swap
    # instead of an instant kill -- without letting the pool consume all system
    # swap. No memory.high: on a box whose swap can be full, the high..max band
    # only stalls; going straight to a clean memory.max OOM yields an
    # attributable "cap death is a finding" kill (AGENTS.md §7). Re-applied on
    # every (re)start; harmless when unchanged.
    echo ${toString memPoolMaxBytes}  > "$slice/pool/memory.max"
    echo ${toString memPoolSwapBytes} > "$slice/pool/memory.swap.max"

    # Publish the resolved pool path so each bwrap launcher can bind it.
    mkdir -p "$XDG_RUNTIME_DIR"
    printf '%s\n' "$slice/pool" > "$XDG_RUNTIME_DIR/mem-pool.cgroup"

    # Stay alive so the slice keeps an active unit. Even across this keeper's own
    # restart the pool survives: systemd cannot trim the slice cgroup while the
    # non-empty .../pool child exists.
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
{
  # Persistent home for the shared pool. Delegated (so the keeper below can
  # create the pool leaf and set its limits) and memory-accounted (so the memory
  # controller reaches the slice's children). A slice's cgroup is NOT destroyed
  # when a service inside it restarts -- that is what makes the pool durable.
  systemd.user.slices."agent-mem-pool" = {
    Unit = {
      Description = "Persistent cgroup v2 memory pool for agent-sandbox commands";
      Documentation = [ "file://${config.home.homeDirectory}/code/AGENTS.md" ];
    };
    Slice = {
      Delegate = true;
      MemoryAccounting = true;
    };
  };

  # Keeper: provisions the pool under the slice and parks a `sleep infinity` so
  # the slice always has an active unit. It creates nothing under its OWN cgroup
  # (the pool is a slice sibling), so it needs no delegation of its own.
  systemd.user.services.agent-mem-pool = {
    Unit = {
      Description = "Shared cgroup v2 memory pool for agent-sandbox commands";
      Documentation = [ "file://${config.home.homeDirectory}/code/AGENTS.md" ];
    };
    Service = {
      # Long-lived (not oneshot): the ExecStart parks a `sleep infinity` so the
      # slice keeps an active unit. See script.
      Type = "simple";
      Slice = "agent-mem-pool.slice";
      MemoryAccounting = true;
      # Delegating cpuset to this service is what makes the user manager
      # enable it in the slice's subtree_control (controllers are enabled for
      # the parent and siblings of a delegatee, systemd.resource-control(5)),
      # putting cpuset into pool/cgroup.controllers -- slices themselves
      # cannot delegate. Harmless no-op until user@.service delegates cpuset
      # (modules/profiles/coding-agent) and the user manager is restarted.
      Delegate = "cpuset";
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

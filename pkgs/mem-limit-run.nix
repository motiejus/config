{
  coreutils,
  gawk,
  writeShellApplication,
}:
# Route a build/test/tool command into the shared agent memory pool (cgroup v2)
# so the AGGREGATE resident memory of all agents' commands is kernel-bounded
# (AGENTS.md §7). The command and its descendants are accounted in the pool; the
# agent session (claude/codex/node) stays OUT of it. The pool is provisioned by
# agent-mem-pool.service and bound into the sandbox at $MEM_POOL by
# pkgs/agent-sandboxes.nix.
writeShellApplication {
  name = "mem-limit-run";
  runtimeInputs = [
    coreutils
    gawk
  ];
  # No errexit: the child's exit status is captured by hand after `wait`.
  bashOptions = [
    "nounset"
    "pipefail"
  ];
  text = ''
    pool=''${MEM_POOL:-/sys/fs/cgroup/pool}

    if [ "$#" -eq 0 ]; then
        echo "usage: MEM_POOL_SUB=name [MEM_POOL_SUB_MAX=bytes] mem-limit-run command [args...]" >&2
        exit 2
    fi

    # Per-job accounting: the shared pool is a delegated parent (controllers
    # enabled for children), so processes must join a named leaf under it --
    # cgroup v2 forbids processes in the parent itself. A leaf name is
    # REQUIRED; there is no shared default, so every job is attributable.
    # The leaf is created on demand; MEM_POOL_SUB_MAX optionally caps it (the
    # pool's aggregate cap always applies hierarchically on top). Cannot test
    # subtree_control with [ -s ]: cgroupfs files always stat as size 0.
    if [ -n "''${MEM_POOL_SUB:-}" ] || [ -n "$(cat "$pool/cgroup.subtree_control" 2>/dev/null)" ]; then
        if [ -z "''${MEM_POOL_SUB:-}" ]; then
            echo "mem-limit-run: pool '$pool' delegates controllers to per-job leaves -- set MEM_POOL_SUB=<job-name> (or point MEM_POOL at a leaf)." >&2
            exit 2
        fi
        sub=''${MEM_POOL_SUB}
        mkdir -p "$pool/$sub" 2>/dev/null || true
        if [ -n "''${MEM_POOL_SUB_MAX:-}" ] && [ -w "$pool/$sub/memory.max" ]; then
            # memory.max accepts only a non-negative integer or the literal
            # "max" -- validate before writing so a bad value fails loudly
            # instead of silently leaving the leaf uncapped.
            case "''${MEM_POOL_SUB_MAX}" in
                max)
                    echo "''${MEM_POOL_SUB_MAX}" > "$pool/$sub/memory.max"
                    ;;
                0 | *[!0-9]* | "")
                    echo "mem-limit-run: invalid MEM_POOL_SUB_MAX=''${MEM_POOL_SUB_MAX} (want a positive integer byte count or 'max')" >&2
                    exit 2
                    ;;
                *)
                    echo "''${MEM_POOL_SUB_MAX}" > "$pool/$sub/memory.max"
                    ;;
            esac
        fi
        aggregate_cap=$(cat "$pool/memory.max" 2>/dev/null || echo '?')
        pool="$pool/$sub"
    else
        aggregate_cap=""
    fi

    if [ ! -w "$pool/cgroup.procs" ]; then
        if [ -d "$pool" ] && [ ! -e "$pool/cgroup.procs" ]; then
            # The pool dir is bind-mounted but its cgroup control files are gone:
            # the mem-pool cgroup was recreated AFTER this sandbox launched, so
            # the bind mount now pins a deleted inode. Nothing here can remount;
            # only re-entering the sandbox re-binds the live pool.
            msg="mem-limit-run: memory pool '$pool' is STALE -- its cgroup was recreated since this sandbox launched (the bind mount pins a now-deleted inode). RELAUNCH the agent session to re-bind the live pool."
        else
            msg="mem-limit-run: shared memory pool '$pool' missing or not writable -- sandbox not extended with cgroup delegation (config: agent-mem-pool.slice + pkgs/agent-sandboxes.nix)."
        fi
        if [ "''${MEM_POOL_REQUIRED:-1}" = "0" ]; then
            echo "$msg Running UNCAPPED (MEM_POOL_REQUIRED=0)." >&2
            exec "$@"
        fi
        echo "$msg Refusing to run uncapped." >&2
        exit 3
    fi

    read_oom() { awk '/^oom_kill /{print $2}' "$pool/memory.events" 2>/dev/null || echo 0; }
    oom_before=$(read_oom)

    # Join the pool in a subshell, then exec so the PID (and its descendants)
    # stay accounted. Writing $BASHPID before exec guarantees the command starts
    # inside the pool. The <&0 is load-bearing: an asynchronous list gets
    # /dev/null on stdin unless stdin is redirected explicitly, which silently
    # starved every piped or heredoc'd command (git commit -F -, python3 -).
    ( echo "$BASHPID" > "$pool/cgroup.procs" && exec "$@" ) <&0 &
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null' INT TERM HUP
    wait "$child"
    status=$?

    oom_after=$(read_oom)
    cap=$(cat "$pool/memory.max" 2>/dev/null || echo '?')
    cur=$(cat "$pool/memory.current" 2>/dev/null || echo '?')
    if [ "$cap" = "max" ] && [ -n "''${aggregate_cap:-}" ]; then
        cap="''${aggregate_cap} (aggregate)"
    fi

    # In a named leaf, memory.events is THIS job's subtree -- oom attribution
    # is exact. Joined directly to a shared pool, it may be any agent's command.
    if [ "''${oom_after:-0}" -gt "''${oom_before:-0}" ]; then
        echo "mem-limit-run: oom_kill rose ''${oom_before}->''${oom_after} in '$pool' during this job. Current ''${cur} B, cap ''${cap} B." >&2
    fi
    if [ "$status" -eq 137 ]; then
        {
            echo "mem-limit-run: FINDING -- this command exited 137 (SIGKILL; likely the pool RSS cap ''${cap} B). Pool current ''${cur} B."
            echo "  Per AGENTS.md §7 a cap death is a finding to REPORT, not a reason to raise the cap."
        } >&2
    fi

    exit "$status"
  '';
}

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
        echo "usage: mem-limit-run command [args...]" >&2
        exit 2
    fi

    if [ ! -w "$pool/cgroup.procs" ]; then
        msg="mem-limit-run: shared memory pool '$pool' missing or not writable -- sandbox not extended with cgroup delegation (config: agent-mem-pool.service + pkgs/agent-sandboxes.nix)."
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
    # inside the pool.
    ( echo "$BASHPID" > "$pool/cgroup.procs" && exec "$@" ) &
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null' INT TERM HUP
    wait "$child"
    status=$?

    oom_after=$(read_oom)
    cap=$(cat "$pool/memory.max" 2>/dev/null || echo '?')
    cur=$(cat "$pool/memory.current" 2>/dev/null || echo '?')

    # Shared pool: distinguish a pool-wide OOM (could be any agent's command)
    # from this command's own SIGKILL.
    if [ "''${oom_after:-0}" -gt "''${oom_before:-0}" ]; then
        echo "mem-limit-run: pool-wide oom_kill rose ''${oom_before}->''${oom_after} during this job (may be another agent's command). Pool current ''${cur} B, cap ''${cap} B." >&2
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

{
  coreutils,
  lib,
  writeShellApplication,
}:
# Run a command in its own leaf of the agent session's cgroup, which
# pkgs/agent-sandboxes.nix binds at /sys/fs/cgroup/pool (AGENTS.md §7). The
# caller (claude/codex) stays outside, so a pool OOM kills only the job.
# No runtimeInputs: they would prepend to the PATH of every wrapped command.
let
  mem-limit-run = writeShellApplication {
    name = "mem-limit-run";
    # No errexit: the child's exit status is captured by hand after `wait`.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      pool=/sys/fs/cgroup/pool
      : "''${1:?usage: [MEM_POOL_SUB_MAX=bytes] mem-limit-run command [args...]}"
      if [ ! -e "$pool/cgroup.procs" ]; then
          echo "mem-limit-run: memory pool '$pool' unavailable or stale -- RELAUNCH the agent session (claudes/codexs)." >&2
          exit 3
      fi
      leaf=$pool/cmd-$$
      ${coreutils}/bin/mkdir -p "$leaf" || exit 3

      read_oom() {
          local k v
          while read -r k v; do [ "$k" = oom_kill ] && echo "$v" && return; done <"$leaf/memory.events"
          echo 0
      }
      oom_before=$(read_oom)

      # Join, then cap, then exec, so nothing starts uncapped. The trap undoes
      # bash's SIGINT/SIGQUIT ignore for background jobs; <&0 keeps stdin, which
      # a background job would get as /dev/null.
      (
          trap - INT QUIT
          echo "$BASHPID" >"$leaf/cgroup.procs" || { echo "mem-limit-run: cannot join '$leaf'" >&2; exit 3; }
          echo "''${MEM_POOL_SUB_MAX:-max}" >"$leaf/memory.max" || { echo "mem-limit-run: cannot set memory.max on '$leaf'" >&2; exit 3; }
          exec "$@"
      ) <&0 &
      child=$!
      trap 'kill -TERM "$child" 2>/dev/null' INT TERM HUP
      wait "$child"
      status=$?
      # A trapped signal returns wait early; wait again for the real status.
      while kill -0 "$child" 2>/dev/null; do
          wait "$child"
          status=$?
      done

      if [ "$(read_oom)" -gt "$oom_before" ]; then
          echo "mem-limit-run: oom_kill in '$leaf' (cap $(<"$leaf/memory.max"))" >&2
      fi
      ${coreutils}/bin/rmdir "$leaf" 2>/dev/null
      exit "$status"
    '';
    # CLAUDE_CODE_SHELL_PREFIX: Claude Code runs every Bash/Monitor command
    # as `agent-shell '<script>'`.
    passthru.agent-shell = writeShellApplication {
      name = "agent-shell";
      text = ''exec ${lib.getExe mem-limit-run} "$BASH" -c "$1"'';
    };
  };
in
mem-limit-run

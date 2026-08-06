{
  lib,
  writeShellApplication,
  pkgs,
  mem-limit-run,
  ...
}:
let
  # Fonts for headless-browser screenshot/pixel tests (e.g. stagit-ng).
  # DOM/text tests work without it; this only silences HarfBuzz tofu.
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

  mkAgentSandbox =
    {
      name,
      tool,
      command,
      statePaths,
      environment ? [ ],
    }:
    let
      tmpDir = "/tmp/${tool}-1001";
      bwrapArgs = [
        "--proc /proc"
        "--dev /dev"
        # Expose ONLY the GPU render node so headless chromium/firefox get a
        # hardware WebGL/EGL context (mesa is already visible via /nix/store),
        # needed for MapLibre map rendering in browser tests. Deliberately the
        # render node, not card0: this grants offscreen GPU compute/rendering
        # but not KMS/modesetting, i.e. no display control or screen capture.
        # The device node alone is not enough -- mesa/libdrm also need the
        # GPU's sysfs view (gpu_args below), and each browser needs a specific
        # launch recipe: AGENTS.md "Browsers with hardware rendering".
        "--dev-bind-try /dev/dri/renderD128 /dev/dri/renderD128"
        # The GPU device alone isn't enough: the browser also needs the NixOS
        # graphics runtime (glvnd, EGL vendor ICDs, GBM, DRI drivers, GLX) at
        # its canonical path, else EGL/GL init falls back to X11 and fails
        # headless. This is the standard surfaceless-EGL/GBM driver set.
        "--ro-bind-try /run/opengl-driver /run/opengl-driver"
        "--ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32"
        # Fresh private /tmp per launch, DISK-backed (a tmpfs here would page
        # out of the same scarce RAM the memory pool protects). Created below;
        # abandoned dirs are reaped by the host's systemd-tmpfiles /tmp aging
        # (`q /tmp 1777 root root 10d`, verified). Tradeoff vs the previous
        # namespace-private tmpfs: sandbox /tmp contents now persist on host
        # disk (same-uid readable) until exit+aging -- acceptable here because
        # the same-uid boundary already includes the rw ~/code bind.
        ''--bind "$sandbox_tmp" /tmp''
        ''--tmpfs "$HOME"''
        # Runtime dir for wayland sockets: cage (headless compositor, the only
        # route to hardware rendering in firefox) refuses to start without it.
        "--perms 0700 --dir /tmp/xdg"
        "--setenv XDG_RUNTIME_DIR /tmp/xdg"
      ]
      ++ map (variable: "--setenv ${variable.name} ${variable.value}") environment
      ++ [
        "--setenv FONTCONFIG_FILE ${fontsConf}"
        ''--symlink "$(readlink -f /run/current-system)" /run/current-system''
        ''--symlink "$(readlink -f /etc/hosts)" /etc/hosts''
        ''--symlink "$(readlink -f /etc/static)" /etc/static''
        ''--symlink "$(readlink -f /etc/static/ssl)" /etc/ssl''
        ''--symlink "$(readlink -f /usr/bin/env)" /usr/bin/env''
        ''--symlink "$(readlink -f "$HOME/.nix-profile")" "$HOME/.nix-profile"''
        "--ro-bind /bin /bin"
        "--ro-bind /nix/store /nix/store"
        "--ro-bind /nix/var/nix/db /nix/var/nix/db"
        "--ro-bind /run/wrappers /run/wrappers"
        "--ro-bind /etc/resolv.conf /etc/resolv.conf"
        "--ro-bind /etc/passwd /etc/passwd"
        "--ro-bind /etc/group /etc/group"
        "--ro-bind /etc/nix /etc/nix"
        ''--ro-bind "$HOME/.config/git" "$HOME/.config/git"''
        "--bind ${tmpDir}/ ${tmpDir}"
      ]
      ++ map (path: ''--bind "$HOME/${path}" "$HOME/${path}"'') statePaths
      ++ [
        ''--bind "$HOME/.cache/zig" "$HOME/.cache/zig"''
        ''--bind "$HOME/.config/nvim" "$HOME/.config/nvim"''
        ''--bind "$HOME/code" "$HOME/code"''
        ''--setenv HOME "$HOME"''
        ''--setenv USER "$USER"''
        "--die-with-parent"
        ''--chdir "$PWD"''
        "--unshare-user"
        "--uid 1001"
        "--gid 1001"
        "--cap-add CAP_SYS_PTRACE"
      ];
    in
    writeShellApplication {
      inherit name;
      # Browser and Node versions come from the flake rather than the user's
      # imperative profile. The Nix store is already visible inside bwrap.
      runtimeInputs = [
        mem-limit-run # `mem-limit-run <cmd>` -> shared cgroup memory pool (AGENTS.md §7)
        pkgs.nodejs
        pkgs.chromium
        pkgs.firefox-bin
        pkgs.playwright-driver.browsers
        # Headless wlroots compositor: gives firefox (or any headed-only app)
        # a real wayland display whose output is a virtual, never-scanned-out
        # buffer -- hardware rendering with no access to the real screen. The
        # sandbox itself guarantees the "no real screen" part: it has no
        # card0/KMS node and no seat, so no cage backend could reach the
        # display even without WLR_BACKENDS=headless.
        pkgs.cage
        pkgs.grim # screenshot the cage output via wlr-screencopy
      ];
      text = ''
        mkdir -p ${tmpDir}
        sandbox_tmp="$(mktemp -d /tmp/${tool}-sbx.XXXXXX)"

        # Bind the shared agent memory pool (cgroup v2) into the sandbox so
        # commands routed through ~/code/.mem-limit-run are accounted against ONE
        # kernel-enforced aggregate RSS cap shared by all agents. The pool is
        # provisioned by the `agent-mem-pool` user service, which publishes its
        # resolved path here. Bound read-write: uid 1001 maps to the host user
        # (1000) that owns the pool, so it can join and size it. The agent
        # session itself is NOT placed in the pool -- only wrapped commands are.
        pool_args=()
        pool_host="$(cat "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mem-pool.cgroup" 2>/dev/null || true)"
        if [ -n "$pool_host" ] && [ -w "$pool_host/cgroup.procs" ]; then
          pool_args=(--bind "$pool_host" /sys/fs/cgroup/pool --setenv MEM_POOL /sys/fs/cgroup/pool)
        else
          echo "agent-sandbox: WARNING -- memory pool unavailable ('$pool_host'); wrapped commands will refuse to run. Is agent-mem-pool.service active?" >&2
        fi

        # Mesa/libdrm resolve the render node through sysfs
        # (/sys/dev/char/<maj:min> -> .../drm/renderD128); without this
        # chromium's hardware GL gets no context and wlroots (cage) finds no
        # render node at all. Exposed surface is minimal: the GPU's own PCI
        # device dir (read-only) plus ONE synthesized /sys/dev/char symlink
        # for the render node -- no card0/KMS, no other devices' sysfs, so the
        # no-display-control/no-screen-capture posture above still holds.
        gpu_args=()
        gpu_sys="$(readlink -f /sys/class/drm/renderD128/device 2>/dev/null || true)"
        if [ -n "$gpu_sys" ]; then
          gpu_args=(
            --ro-bind "$gpu_sys" "$gpu_sys"
            --symlink "$(readlink -f /sys/class/drm/renderD128)"
            "/sys/dev/char/$(cat /sys/class/drm/renderD128/dev)"
          )
        else
          echo "agent-sandbox: WARNING -- GPU render node sysfs not found; browsers will fall back to software rendering." >&2
        fi

        exec ${pkgs.bubblewrap}/bin/bwrap \
          ${lib.concatStringsSep " \\\n          " bwrapArgs} \
          "''${pool_args[@]}" \
          "''${gpu_args[@]}" \
          -- ${lib.escapeShellArgs command} "$@"
      '';
    };
in
{
  claudes = mkAgentSandbox {
    name = "claudes";
    tool = "claude";
    command = [
      "claude"
      "--dangerously-skip-permissions"
    ];
    statePaths = [
      ".claude.json"
      ".claude"
    ];
    environment = [
      {
        name = "CLAUDE_CODE_MAX_OUTPUT_TOKENS";
        value = "100000";
      }
    ];
  };

  codexs = mkAgentSandbox {
    name = "codexs";
    tool = "codex";
    command = [
      "codex"
      "--dangerously-bypass-approvals-and-sandbox"
    ];
    statePaths = [ ".codex" ];
  };
}

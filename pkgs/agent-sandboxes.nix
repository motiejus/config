{
  lib,
  writeShellApplication,
  pkgs,
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
        "--dev-bind-try /dev/dri/renderD128 /dev/dri/renderD128"
        # The GPU device alone isn't enough: the browser also needs the NixOS
        # graphics runtime (glvnd, EGL vendor ICDs, GBM, DRI drivers, GLX) at
        # its canonical path, else EGL/GL init falls back to X11 and fails
        # headless. This is the standard surfaceless-EGL/GBM driver set.
        "--ro-bind-try /run/opengl-driver /run/opengl-driver"
        "--ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32"
        "--tmpfs /tmp"
        ''--tmpfs "$HOME"''
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
        pkgs.nodejs
        pkgs.chromium
        pkgs.firefox-bin
        pkgs.playwright-driver.browsers
      ];
      text = ''
        mkdir -p ${tmpDir} && \
        ${pkgs.bubblewrap}/bin/bwrap \
          ${lib.concatStringsSep " \\\n          " bwrapArgs} \
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

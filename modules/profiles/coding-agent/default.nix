{
  config,
  pkgs,
  ...
}:
{
  # Each of these ships its bwrap wrapper plus the naked CLI: `claudes` and
  # `claude`, `codexs` and `codex`.
  environment.systemPackages = with pkgs; [
    claudes
    codexs
  ];

  # The identity the sandboxes present inside their user namespace. It never
  # logs in and owns nothing on disk -- the namespace maps it back to the host
  # user -- but tools that resolve their own uid (node's os.userInfo(), which
  # qwen-code calls at import time) abort unless it has a passwd entry.
  users = {
    users.coding-agent = {
      isSystemUser = true;
      uid = pkgs.claudes.agentUid;
      group = "coding-agent";
      home = config.users.users.${config.mj.username}.home;
    };
    groups.coding-agent.gid = pkgs.claudes.agentUid;
  };

  # Stock user@.service delegates only "pids memory cpu" to the per-user
  # manager; add cpuset so the agent mem-pool (shared/home/dev.nix) can offer
  # it to per-job leaves. Drop-in Delegate= lists ADD to the fragment's list
  # (only the empty string resets it, systemd.resource-control(5)); the full
  # list is spelled out anyway. The user manager caches its controller set at
  # startup and user@ is not restarted on switch, so this takes effect per
  # user at the next full re-login/reboot.
  systemd.services."user@".serviceConfig.Delegate = "pids memory cpu cpuset";

  # Make the GPU render node world-accessible so the sandboxes get a hardware
  # WebGL/EGL context for browser-based rendering tests. The bwrap userns maps
  # the agent to the host user but drops supplementary groups, so it can never
  # be in the `render` group; a world-rw render node is the way it can open the
  # bound /dev/dri/renderD128. Render node only -- offscreen GPU compute/render,
  # no card0/KMS, so no display control or screen capture.
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
  '';
}

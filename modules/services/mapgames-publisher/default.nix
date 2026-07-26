{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.mapgames-publisher;

  # The stateful publisher is the sole writer of /var/lib/mapgames. It is a
  # thin wrapper around the reviewed mapgames-publisher.py state machine; there
  # is no daemon user and no Caddy-writable object directory.
  #
  # The state-machine script ships inside the maps.jakstys.lt source tree now
  # (repo root), not in this config repo; pkgs.mapgames exposes its store path
  # as `publisherScript` so there is exactly one copy under version control.
  publisher =
    pkgs.runCommand "mapgames-publisher"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin $out/libexec
        cp ${pkgs.mapgames.publisherScript} $out/libexec/mapgames-publisher.py
        makeWrapper ${pkgs.python3}/bin/python3 $out/bin/mapgames-publisher \
          --add-flags $out/libexec/mapgames-publisher.py
      '';
in
{
  options.mj.services.mapgames-publisher = {
    enable = lib.mkEnableOption "content-addressed stateful map/search publisher";

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mapgames";
      description = ''
        Root of the durable publisher state. Its object/, releases/ and state/
        subdirectories and the atomically switched `current` symlink live here.
        Caddy serves only `''${stateDir}/current`.
      '';
    };

    candidate = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mapgames;
      description = ''
        The candidate served tree (the immutable content-addressed web graph
        produced by the web-graph Zig build tool). It is passed to the seed
        oneshot as an explicit immutable Nix store input and drives
        restartTriggers, so a changed candidate re-runs the seed before Caddy
        starts.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = publisher;
      description = "The mapgames-publisher command package.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Root-owned state layout, mode 0755. The immutable object files the
    # publisher installs are chmod 0644 at install time; all copy/validation
    # work happens in a root-only 0750 `.staging-*` directory on this same
    # filesystem, and Caddy receives read/execute only after the atomic rename
    # into the served 0755 layout. tmpfiles creates the stable directories; it
    # never touches `current`, `.staging-*` or any object (the publisher owns
    # those and their exact modes).
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}          0755 root root -"
      "d ${cfg.stateDir}/objects  0755 root root -"
      "d ${cfg.stateDir}/releases 0755 root root -"
      "d ${cfg.stateDir}/state    0755 root root -"
    ];

    # The exact root-running seed oneshot (plan §Step 9.2). Its only writer
    # command is `mapgames-publisher seed`. It runs before and is required by
    # Caddy, so on a first install Caddy cannot start until `current` exists,
    # and on an upgrade a publisher failure leaves the previous `current` and
    # the running Caddy untouched.
    systemd.services.mapgames-publisher-seed = {
      description = "Seed/upgrade the content-addressed map/search release";
      wantedBy = [ "multi-user.target" ];
      before = [ "caddy.service" ];
      requiredBy = [ "caddy.service" ];
      # time-sync.target: the seed's cadence/grace gates are wall-clock based, so
      # it must not run against a pre-NTP clock if that can be avoided. (An
      # unchanged candidate is a no-op the publisher short-circuits BEFORE any
      # clock gate, so a still-skewed clock can never fail this unit — and thus
      # never block caddy.service, which requires it — over a release that is
      # already published.)
      after = [
        "local-fs.target"
        "time-sync.target"
      ];
      # Re-run when the candidate store path changes (a new build).
      restartTriggers = [ cfg.candidate ];
      unitConfig = {
        RequiresMountsFor = cfg.stateDir;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        UMask = "0022";
        ExecStart = ''
          ${cfg.package}/bin/mapgames-publisher seed \
            --state-dir ${cfg.stateDir} \
            --candidate ${cfg.candidate}
        '';
      };
    };

    # Rollback / roll-forward / GC are explicit, locked publisher subcommands a
    # human runs against the same state dir — never additional writer services:
    #   mapgames-publisher rollback     --state-dir ${cfg.stateDir}
    #   mapgames-publisher roll-forward --state-dir ${cfg.stateDir}
    #   mapgames-publisher gc           --state-dir ${cfg.stateDir}
    environment.systemPackages = [ cfg.package ];

    mj.base.unitstatus.units = [ "mapgames-publisher-seed" ];
  };
}

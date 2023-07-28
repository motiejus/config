{
  config,
  lib,
  pkgs,
  ...
}: {
  options.mj.services.updaterbot = with lib.types; {
    enableMaster = lib.mkEnableOption "Enable system updater orchestrator";
    enableDeployer = lib.mkEnableOption "Enable system updater deployer";
    deployDerivations = lib.mkOption {type = listOf str;};
    uidgid = lib.mkOption {type = int;};
    repo = lib.mkOption {type = str;};
  };

  config = lib.mkIf config.mj.services.updaterbot.enableMaster {
    users = {
      users = {
        # TODO: git config --global user.email updaterbot@jakstys.lt
        # TODO: ssh-keygen -t ed25519
        updaterbot = {
          description = "Dear Updaterbot";
          home = "/var/lib/updaterbot";
          useDefaultShell = true;
          group = "updaterbot";
          isSystemUser = true;
          createHome = true;
          uid = config.mj.services.updaterbot.uidgid;
        };
      };

      groups = {
        updaterbot.gid = config.mj.services.updaterbot.uidgid;
      };
    };

    systemd.services.updaterbot = {
      description = "Update all known systems";
      preStart = ''
        if [[ -f .ssh/id_ed25519 ]]; then exit; fi

        ${pkgs.openssh}/bin/ssh-keygen -N "" -t ed25519 -f .ssh/id_ed25519
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "updaterbot";
        WorkingDirectory = config.users.users.updaterbot.home;
      };
      script = let
        deployDerivations = builtins.concatStringsSep " " config.mj.services.updaterbot.deployDerivations;
      in ''
        set -x
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $HOME/.ssh/id_ed25519"
        if [[ ! -d config ]]; then
          ${pkgs.git}/bin/git clone ${config.mj.services.updaterbot.repo} config
          cd config
        else
          cd config
          ${pkgs.git}/bin/git fetch origin
          ${pkgs.git}/bin/git reset --hard origin/main
        fi

        export PATH=$PATH:${pkgs.git}/bin:${pkgs.nix}/bin
        ${pkgs.nix}/bin/nix flake update --accept-flake-config --commit-lock-file
        ${pkgs.git}/bin/git push origin main

        export PATH=$PATH:${pkgs.openssh}/bin
        exec ${pkgs.nix}/bin/nix run .#deploy-rs -- ${deployDerivations}
      '';
    };

    #systemd.timers.updaterbot = {
    #  description = "updaterbot timer";
    #  wantedBy = ["timers.target"];
    #  timerConfig.OnCalendar = "";
    #};

    mj.base.unitstatus.units = ["updaterbot"];

    nix.settings.trusted-users = ["updaterbot"];
  };
}

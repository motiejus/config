{
  config,
  lib,
  pkgs,
  ...
}: let
  mkOptional = {
    derivationTarget,
    pingTarget,
  }: ''
    if ${pkgs.inetutils}/bin/ping -c 1 ${pingTarget}; then
      ${pkgs.deploy-rs.deploy-rs}/bin/deploy \
        --ssh-opts="-i ''${CREDENTIALS_DIRECTORY}/ssh-key" \
        --ssh-user=deployerbot-follower \
        --confirm-timeout 60 \
        --targets ${derivationTarget} -- \
          --accept-flake-config || EXITCODE=1
    fi
  '';
in {
  options.mj.services.deployerbot.main = with lib.types; {
    enable = lib.mkEnableOption "Enable system updater orchestrator";
    deployDerivations = lib.mkOption {type = listOf str;};
    deployIfPresent = lib.mkOption {
      type = listOf (submodule {
        options = {
          derivationTarget = lib.mkOption {type = str;};
          pingTarget = lib.mkOption {type = str;};
        };
      });
      default = [];
    };
    uidgid = lib.mkOption {type = int;};
    repo = lib.mkOption {type = str;};
  };

  options.mj.services.deployerbot.follower = with lib.types; {
    enable = lib.mkEnableOption "Allow system to be deployed with deployerbot";
    sshAllowSubnets = lib.mkOption {type = listOf str;};
    publicKey = lib.mkOption {type = str;};
    uidgid = lib.mkOption {type = int;};
  };

  config = lib.mkMerge [
    (let
      cfg = config.mj.services.deployerbot.main;
    in
      lib.mkIf cfg.enable {
        # TODO: git config --global user.email bot@jakstys.lt
        users.users.deployerbot-main = {
          description = "Deployerbot Main";
          home = "/var/lib/deployerbot-main";
          shell = "/bin/sh";
          group = "deployerbot-main";
          isSystemUser = true;
          createHome = true;
          uid = cfg.uidgid;
        };
        users.groups.deployerbot-main.gid = cfg.uidgid;

        systemd.services.deployerbot = {
          description = "Update all known systems";
          environment = {TZ = "UTC";};
          path = [pkgs.git pkgs.openssh pkgs.nix];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            User = "deployerbot-main";
            WorkingDirectory = config.users.users.deployerbot-main.home;
            LoadCredential = ["ssh-key:/etc/ssh/ssh_host_ed25519_key"];
          };
          script = let
            deployDerivationsStr = builtins.concatStringsSep " " cfg.deployDerivations;
          in ''
            set -x
            export GIT_SSH_COMMAND="ssh -i ''${CREDENTIALS_DIRECTORY}/ssh-key"
            if [[ ! -d config ]]; then
              git clone ${cfg.repo} config
              cd config
            else
              cd config
              git fetch origin
              git reset --hard origin/main
            fi

            nix flake update --accept-flake-config --commit-lock-file
            nix flake check
            git push origin main

            ${pkgs.deploy-rs.deploy-rs}/bin/deploy \
              --ssh-opts="-i ''${CREDENTIALS_DIRECTORY}/ssh-key" \
              --ssh-user=deployerbot-follower \
              --confirm-timeout 60 \
              --targets ${deployDerivationsStr} -- \
                --accept-flake-config

            # Optional deployments
            EXITCODE=0
            ${lib.concatLines (map mkOptional cfg.deployIfPresent)}

            exit $EXITCODE
          '';
        };

        systemd.timers.deployerbot = {
          description = "deployerbot-main timer";
          wantedBy = ["timers.target"];
          timerConfig.OnCalendar = "*-*-* 23:30:00 UTC";
        };

        mj.base.unitstatus.units = ["deployerbot"];

        nix.settings.trusted-users = ["deployerbot-main"];
      })

    (let
      cfg = config.mj.services.deployerbot.follower;
    in
      lib.mkIf cfg.enable {
        users.users.deployerbot-follower = {
          description = "Deployerbot Follower";
          home = "/var/lib/deployerbot-follower";
          shell = "/bin/sh";
          group = "deployerbot-follower";
          extraGroups = ["wheel"];
          isSystemUser = true;
          createHome = true;
          uid = cfg.uidgid;
          openssh.authorizedKeys.keys = let
            restrictedPubKey = "from=\"${builtins.concatStringsSep "," cfg.sshAllowSubnets}\" " + cfg.publicKey;
          in [restrictedPubKey];
        };
        users.groups.deployerbot-follower.gid = cfg.uidgid;
        nix.settings.trusted-users = ["deployerbot-follower"];
      })
  ];
}

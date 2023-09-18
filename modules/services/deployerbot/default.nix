{
  config,
  lib,
  pkgs,
  myData,
  ...
}: let
  cfg = config.mj.services.deployerbot;
  mkOptional = {
    derivationTarget,
    altHostname,
  }: ''
    if ${pkgs.inetutils}/bin/ping -c 1 ${altHostname}; then
      ${pkgs.deploy-rs}/bin/deploy \
        --ssh-opts="-i ''${CREDENTIALS_DIRECTORY}/ssh-key" \
        --ssh-user=deployerbot-follower \
        --confirm-timeout 60 \
        --hostname ${altHostname} \
        --targets ${derivationTarget} -- \
          --accept-flake-config
    fi
  '';
in {
  options.mj.services.deployerbot.main = with lib.types; {
    enable = lib.mkEnableOption "Enable system updater orchestrator";
    deployDerivations = lib.mkOption {type = listOf str;};
    deployIfPresent = lib.mkOption {
      type = listOf (submodule (
        {...}: {
          options = {
            derivationTarget = lib.mkOption {type = str;};
            altHostname = lib.mkOption {type = str;};
          };
        }
      ));
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
    (lib.mkIf cfg.main.enable {
      # TODO: git config --global user.email bot@jakstys.lt
      users.users.deployerbot-main = {
        description = "Deployerbot Main";
        home = "/var/lib/deployerbot-main";
        useDefaultShell = true;
        group = "deployerbot-main";
        isSystemUser = true;
        createHome = true;
        uid = cfg.main.uidgid;
      };
      users.groups.deployerbot-main.gid = cfg.main.uidgid;

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
          deployDerivationsStr = builtins.concatStringsSep " " cfg.main.deployDerivations;
        in ''
          set -x
          export GIT_SSH_COMMAND="ssh -i ''${CREDENTIALS_DIRECTORY}/ssh-key"
          if [[ ! -d config ]]; then
            git clone ${cfg.main.repo} config
            cd config
          else
            cd config
            git fetch origin
            git reset --hard origin/main
          fi

          nix flake update --accept-flake-config --commit-lock-file

          ${pkgs.deploy-rs}/bin/deploy \
            --ssh-opts="-i ''${CREDENTIALS_DIRECTORY}/ssh-key" \
            --ssh-user=deployerbot-follower \
            --confirm-timeout 60 \
            --targets ${deployDerivationsStr} -- \
              --accept-flake-config

          # Optional deployments
          ${lib.concatLines (map mkOptional cfg.main.deployIfPresent)}

          # done
          git push origin main
        '';
      };

      systemd.timers.deployerbot = {
        description = "deployerbot-main timer";
        wantedBy = ["timers.target"];
        # 15:38 UTC was the latest merge that I have observed since
        # making the commit by looking at 3 commits of this repo.
        # Let's try to be optimistic.
        timerConfig.OnCalendar = "*-*-* 23:30:00 UTC";
      };

      mj.base.unitstatus.units = ["deployerbot"];

      nix.settings.trusted-users = ["deployerbot-main"];
    })
    (lib.mkIf cfg.follower.enable {
      users.users = {
        deployerbot-follower = {
          description = "Deployerbot Follower";
          home = "/var/lib/deployerbot-follower";
          useDefaultShell = true;
          group = "deployerbot-follower";
          extraGroups = ["wheel"];
          isSystemUser = true;
          createHome = true;
          uid = cfg.follower.uidgid;
          openssh.authorizedKeys.keys = let
            restrictedPubKey = "from=\"${builtins.concatStringsSep "," cfg.follower.sshAllowSubnets}\" " + cfg.follower.publicKey;
          in [restrictedPubKey];
        };
      };
      users.groups.deployerbot-follower.gid = cfg.follower.uidgid;
      nix.settings.trusted-users = ["deployerbot-follower"];
    })
  ];
}

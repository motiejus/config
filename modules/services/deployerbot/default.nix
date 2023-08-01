{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
  options.mj.services.deployerbot.main = with lib.types; {
    enable = lib.mkEnableOption "Enable system updater orchestrator";
    deployDerivations = lib.mkOption {type = listOf str;};
    uidgid = lib.mkOption {type = int;};
    repo = lib.mkOption {type = str;};
  };

  options.mj.services.deployerbot.follower = with lib.types; {
    enable = lib.mkEnableOption "Allow system to be deployed with deployerbot";
    publicKey = lib.mkOption {type = str;};
    uidgid = lib.mkOption {type = int;};
  };

  config = lib.mkMerge [
    (with config.mj.services.deployerbot.main;
      lib.mkIf enable {
        # TODO: git config --global user.email bot@jakstys.lt
        users.users.deployerbot-main = {
          description = "Deployerbot Main";
          home = "/var/lib/deployerbot-main";
          useDefaultShell = true;
          group = "deployerbot-main";
          isSystemUser = true;
          createHome = true;
          uid = uidgid;
        };
        users.groups.deployerbot-main.gid = uidgid;

        systemd.services.deployerbot = {
          description = "Update all known systems";
          serviceConfig = {
            Type = "oneshot";
            User = "deployerbot-main";
            WorkingDirectory = config.users.users.deployerbot-main.home;
            LoadCredential = ["ssh-key:/etc/ssh/ssh_host_ed25519_key"];
          };
          script = let
            deployDerivationsStr = builtins.concatStringsSep " " deployDerivations;
          in ''
            set -x
            export PATH=$PATH:${pkgs.git}/bin:${pkgs.openssh}/bin:${pkgs.nix}/bin

            export GIT_SSH_COMMAND="ssh -i ''${CREDENTIALS_DIRECTORY}/ssh-key"
            if [[ ! -d config ]]; then
              git clone ${repo} config
              cd config
            else
              cd config
              git fetch origin
              git reset --hard origin/main
            fi

            nix flake update --accept-flake-config --commit-lock-file

            nix run .#deploy-rs -- \
              --ssh-opts="-i ''${CREDENTIALS_DIRECTORY}/ssh-key" \
              --ssh-user=deployerbot-follower \
              --targets ${deployDerivationsStr}

            git push origin main
          '';
        };

        systemd.timers.deployerbot = {
          description = "deployerbot-main timer";
          wantedBy = ["timers.target"];
          # 15:38 UTC was the latest merge that I have observed since
          # making the commit by looking at 3 commits of this repo.
          # Let's try to be optimistic.
          timerConfig.OnCalendar = "*-*-* 16:00:00 UTC";
        };

        mj.base.unitstatus.units = ["deployerbot"];

        nix.settings.trusted-users = ["deployerbot-main"];
      })
    (with config.mj.services.deployerbot.follower;
      lib.mkIf enable {
        users.users = {
          deployerbot-follower = {
            description = "Deployerbot Follower";
            home = "/var/lib/deployerbot-follower";
            useDefaultShell = true;
            group = "deployerbot-follower";
            extraGroups = ["wheel"];
            isSystemUser = true;
            createHome = true;
            uid = uidgid;
            openssh.authorizedKeys.keys = let
              restrictedPubKey = "from=\"${myData.tailscale_subnet.pattern}\" " + publicKey;
            in [restrictedPubKey];
          };
        };
        users.groups.deployerbot-follower.gid = uidgid;
        nix.settings.trusted-users = ["deployerbot-follower"];
      })
  ];
}

{ config, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    bats
    unzip
    rclone
    nodejs
    awscli2
    mysql80
    kubectl
    kubectx
    terraform
    github-cli
    docker-compose
    gcloud-wrapped
    kubectl-node-shell
    ssm-session-manager-plugin
    pkgs.pkgs-unstable.claude-code
  ];

  home-manager.users.${config.mj.username} = {
    home.sessionVariables = {
      GOFLAGS = "-tags=big,integration,cluster_integration";
      GOPRIVATE = "github.com/chronosphereio";
      BUILDKIT_COLORS = "run=123,20,245:error=yellow:cancel=blue:warning=white";
      CLAUDE_CODE_USE_VERTEX = "1";
      CLOUD_ML_REGION = "global";
      ANTHROPIC_VERTEX_PROJECT_ID = "chronosphere-rc-b";
    };
    programs = {
      git.settings = {
        url."git@github.com:".insteadOf = "https://github.com";
        user.useConfigOnly = true;
      };
      bash.initExtra = ''
        droidcli() {
          (cd $HOME/dev/monorepo; bin/droidcli "$@")
        }
        mj_ps1_extra() {
            if [[ $PWD =~ $HOME/dev ]]; then
                kubectl config view --minify -o jsonpath={.current-context}:{..namespace}
            fi
        }
        export PS1=$(echo "$PS1" | sed 's;\\n;$(mj_ps1_extra);')
      '';
    };
  };
}

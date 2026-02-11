{ config, pkgs, ... }:
{
  mj.base.users = {
    email = null;
    wrapGo = true;
  };

  networking = {
    hosts."127.0.0.1" = [
      "go"
      "go."
    ];
    firewall.allowedTCPPorts = [ 80 ];
  };

  environment.systemPackages = with pkgs; [
    #swc
    turbo
    nodejs
    typescript
    #concurrently
    bats
    unzip
    rclone
    mysql80
    kubectl
    kubectx
    chronoctl
    terraform
    github-cli
    #pkgs.pkgs-unstable.claude-code
    docker-compose
    gcloud-wrapped
    kubectl-node-shell

    liburing.dev
  ];

  programs._1password.enable = true;

  home-manager.users.${config.mj.username} = {
    home.sessionVariables = {
      GOFLAGS = "-tags=big,integration,cluster_integration";
      GOPRIVATE = "github.com/chronosphereio";
      BUILDKIT_COLORS = "run=123,20,245:error=yellow:cancel=blue:warning=white";
      CLAUDE_CODE_USE_VERTEX = "1";
      CLOUD_ML_REGION = "europe-west1";
      ANTHROPIC_VERTEX_PROJECT_ID = "chronosphere-rc-b";
    };
    programs = {
      git.settings = {
        url."git@github.com:".insteadOf = "https://github.com";
        user.useConfigOnly = true;
      };
      chromium.extensions = [
        { id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"; } # 1password
        { id = "mdkgfdijbhbcbajcdlebbodoppgnmhab"; } # GoLinks
        { id = "kgjfgplpablkjnlkjmjdecgdpfankdle"; } # Zoom
      ];
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

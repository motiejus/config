{ config, pkgs, ... }:
{
  mj.base.users.email = null;

  environment.systemPackages = with pkgs; [
    #swc
    #nodejs
    #typescript
    #concurrently
    bats
    unzip
    rclone
    mysql80
    kubectl
    kubectx
    terraform
    github-cli
    claude-code
    docker-compose
    google-cloud-sdk
    kubectl-node-shell
  ];

  programs._1password.enable = true;

  services.clamav = {
    updater.enable = true;
    daemon = {
      enable = true;
      settings = {
        ScanMail = false;
        ScanArchive = false;
        ExcludePath = [
          "^/proc"
          "^/sys"
          "^/dev"
          "^/nix"
          "^/var"
          "^/home/.cache"
          "^/home/.go"
          "^/home/dev"
          "^/home/code"
        ];
      };
    };
  };
  # TODO remove once 24.05 is out
  systemd.services.clamav-daemon.serviceConfig = {
    StateDirectory = "clamav";
    RuntimeDirectory = "clamav";
    User = "clamav";
    Group = "clamav";
  };

  systemd.services.clamav-freshclam.serviceConfig = {
    StateDirectory = "clamav";
    User = "clamav";
    Group = "clamav";
  };

  home-manager.users.${config.mj.username} = {
    home.sessionVariables = {
      GOFLAGS = "-tags=big,integration,cluster_integration";
      GOPRIVATE = "github.com/chronosphereio";
      BUILDKIT_COLORS = "run=123,20,245:error=yellow:cancel=blue:warning=white";
      CLAUDE_CODE_USE_VERTEX = "1";
      CLOUD_ML_REGION = "us-east5";
      ANTHROPIC_VERTEX_PROJECT_ID = "chronosphere-rc-b";
    };
    programs = {
      git.extraConfig = {
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

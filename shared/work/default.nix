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

  services.nginx = {
    enable = true;
    defaultListenAddresses = [ "0.0.0.0" ];
    virtualHosts = {
      "_" = {
        default = true;
        root = "/var/run/nginx/motiejus";
        locations."/".extraConfig = ''
          autoindex on;
        '';
      };
      "go" = {
        addSSL = true;
        sslCertificate = "${../../shared/certs/go.pem}";
        sslCertificateKey = "${../../shared/certs/go.key}";
        locations."/".extraConfig = ''
          return 301 https://golinks.io$request_uri;
        '';
      };
    };
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
    claude-code
    docker-compose
    gcloud-wrapped
    kubectl-node-shell

    liburing.dev
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

  systemd.services = {
    # TODO remove once 24.05 is out
    clamav-daemon.serviceConfig = {
      StateDirectory = "clamav";
      RuntimeDirectory = "clamav";
      User = "clamav";
      Group = "clamav";
    };

    clamav-freshclam.serviceConfig = {
      StateDirectory = "clamav";
      User = "clamav";
      Group = "clamav";
    };

    nginx.serviceConfig.BindPaths = [ "/home/motiejus/www:/var/run/nginx/motiejus" ];
  };

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

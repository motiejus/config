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
    docker-compose
    google-cloud-sdk
    kubectl-node-shell

    (pkgs.terraform.withPlugins (_: [
      (pkgs.terraform-providers.mkProvider {
        owner = "chronosphereio";
        repo = "terraform-provider-chronosphere";
        spdx = "Apache-2.0";
        rev = "v1.7.0";
        hash = "sha256-BfVR/1wf6YH7mc7kXPjk2cI8u3/k0Zi8+Xu7Kg6AN80=";
        vendorHash = "sha256-UxoFbiQa5RgNI90oUy4twembgA8jseeu6Hc/9KTwJKA=";
        homepage = "https://registry.terraform.io/providers/chronosphereio/chronosphere";
      })
    ]))
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
      GOFLAGS = "-tags=integration,cluster_integration";
      GOPRIVATE = "github.com/chronosphereio";
      BUILDKIT_COLORS = "run=123,20,245:error=yellow:cancel=blue:warning=white";
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

# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let ssh_pubkeys = {
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
    vno1_root = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMiWb7yeSeuFCMZWarKJD6ZSxIlpEHbU++MfpOIy/2kh";
}; in {
  imports =
    [
      /etc/nixos/hardware-configuration.nix /etc/nixos/zfs.nix
    ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      authorizedKeys = builtins.attrValues ssh_pubkeys;
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  security.sudo = {
    wheelNeedsPassword = false;
    execWheelOnly = true;
  };

  time.timeZone = "UTC";

  users = {
    mutableUsers = false;

    users = {
      git = {
        description = "Gitea Service";
        home = "/var/lib/gitea";
        useDefaultShell = true;
        group = "gitea";
        isSystemUser = true;
      };

      motiejus = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ ssh_pubkeys.motiejus ];
      };
    };
  };

  environment.systemPackages = with pkgs; [
    jq
    vim
    git
    tmux
    tree
    wget
    lsof
    file
    htop
    ncdu
    sqlite
    ripgrep
    binutils
    pciutils
    headscale
    nixos-option
  ];

  programs.mtr.enable = true;
  programs.mosh.enable = true;

  services = {
    zfs = {
      autoSnapshot = {
        enable = true;
        frequent = 0;
        hourly = 24;
        daily = 7;
        weekly = 0;
        monthly = 0;
      };

      autoScrub.enable = true;
      trim.enable = true;
      expandOnBoot = "all";
    };

    openssh = {
      enable = true;
      passwordAuthentication = false;
      permitRootLogin = "no";
      extraConfig = ''
        AcceptEnv GIT_PROTOCOL
      '';
    };

    locate = {
      enable = true;
      locate = pkgs.plocate;
      localuser = null;
    };

    headscale = {
      enable = true;
      serverUrl = "https://vpn.jakstys.lt";
      openIdConnect = {
        issuer = "https://git.jakstys.lt/";
        clientId = "1c5fe796-452c-458d-b295-71a9967642fc";
        clientSecretFile = "/var/src/secrets/headscale/oidc_client_secret";
      };
      settings = {
        ip_prefixes = [ "100.89.176.0/20" ];
        dns_config = {
          nameservers = [ "1.1.1.1" "8.8.4.4" ];
          magic_dns = true;
          base_domain = "jakst";
        };
      };
    };

    tailscale.enable = true;

    gitea = {
      enable = true;
      user = "git";
      database.user = "git";
      domain = "git.jakstys.lt";
      rootUrl = "https://git.jakstys.lt";
      httpAddress = "127.0.0.1";
      httpPort = 3000;
      settings = {
        admin.DISABLE_REGULAR_ORG_CREATION = true;
        api.ENABLE_SWAGGER = false;
        mirror.ENABLED = false;
        other.SHOW_FOOTER_VERSION = false;
        packages.ENABLED = false;
        repository.DEFAULT_REPO_UNITS = "repo.code,repo.releases";
        repository.DISABLE_MIGRATIONS = true;
        repository.DISABLE_STARS = true;
        repository.ENABLE_PUSH_CREATE_USER = true;
        security.LOGIN_REMEMBER_DAYS = 30;
        server.ENABLE_GZIP = true;
        server.LANDING_PAGE = "/motiejus";
        service.DISABLE_REGISTRATION = true;
        service.ENABLE_TIMETRACKING = false;
        service.ENABLE_USER_HEATMAP = false;
        service.SHOW_MILESTONES_DASHBOARD_PAGE = false;
        session.COOKIE_SECURE = true;
        "service.explore".REQUIRE_SIGNIN_VIEW = true;
        "service.explore".DISABLE_USERS_PAGE = true;
      };
    };

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      virtualHosts."vpn.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:8080
      '';
      virtualHosts."git.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
    };
  };

  networking = {
    hostName = "hel1-a";
    firewall = {
      allowedTCPPorts = [ 80 443 ];
      allowedUDPPorts = [ 443 ];
      checkReversePath = "loose"; # tailscale insists on this
    };
  };

  system = {
    copySystemConfiguration = true;
    autoUpgrade.enable = true;
    autoUpgrade = {
      allowReboot = true;
      rebootWindow = {
        lower = "00:00";
        upper = "00:30";
      };
    };
  };

  # Do not change
  system.stateVersion = "22.11";
}


{
  config,
  pkgs,
  lib,
  agenix,
  myData,
  ...
}: let
  backup_paths = {
    var_lib = {
      mountpoint = "/var/lib";
      zfs_name = "rpool/nixos/var/lib";
      paths = [
        "/var/lib/.snapshot-latest/gitea"
        "/var/lib/.snapshot-latest/headscale"
        "/var/lib/.snapshot-latest/matrix-synapse"
      ];
      backup_at = "*-*-* 00:11:00";
    };
    var_log = {
      mountpoint = "/var/log";
      zfs_name = "rpool/nixos/var/log";
      paths = ["/var/log/.snapshot-latest/caddy/"];
      patterns = [
        "+ /var/log/.snapshot-latest/caddy/access-jakstys.lt.log-*.zst"
        "- *"
      ];
      backup_at = "*-*-* 00:10:00";
    };
  };

  turn_cert_dir = "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/turn.jakstys.lt";
  gitea_uidgid = 995;

  # functions
  mountLatest = (
    {
      mountpoint,
      zfs_name,
    }: ''
      set -euo pipefail
      ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest &>/dev/null || :
      mkdir -p ${mountpoint}/.snapshot-latest
      ${pkgs.util-linux}/bin/mount -t zfs $(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name ${zfs_name} | sort | tail -1) ${mountpoint}/.snapshot-latest
    ''
  );

  umountLatest = (
    {mountpoint, ...}: ''exec ${pkgs.util-linux}/bin/umount ${mountpoint}/.snapshot-latest''
  );
in {
  imports = [
    ./hardware-configuration.nix
    ./zfs.nix
  ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      authorizedKeys = builtins.attrValues myData.ssh_pubkeys;
      hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
    };
  };

  mj = {
    stateVersion = "22.11";
    timeZone = "UTC";

    base = {
      initrd = {
        enable = true;
        authorizedKeys = builtins.attrValues myData.ssh_pubkeys;
        hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
      };
      snapshot = {
        enable = true;
        mountpoints = ["/var/lib" "/var/log"];
      };

      zfsborg = {
        enable = true;
        repo = "zh2769@zh2769.rsync.net:hel1-a.servers.jakst";
        passwdPath = config.age.secrets.borgbackup-password.path;
        mountpoints = {
          "/var/lib" = {
            paths = [
              "/var/lib/.snapshot-latest/gitea"
              "/var/lib/.snapshot-latest/headscale"
              "/var/lib/.snapshot-latest/matrix-synapse"
            ];
            backup_at = "*-*-* 00:11:00";
          };
          "/var/log" = {
            paths = ["/var/log/.snapshot-latest/caddy/"];
            patterns = [
              "+ /var/log/.snapshot-latest/caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 00:10:00";
          };
        };
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
        # see TODO in base/unitstatus/default.nix
        #units = ["zfs-scrub"];
      };
    };
  };

  users = {
    users.git = {
      description = "Gitea Service";
      home = "/var/lib/gitea";
      useDefaultShell = true;
      group = "gitea";
      isSystemUser = true;
      uid = gitea_uidgid;
    };

    groups.gitea.gid = gitea_uidgid;
  };

  environment = {
    systemPackages = with pkgs; [
      git
      tmux
      htop
      #ncdu
      nmap
      ipset
      ngrep
      p7zip
      pwgen
      parted
      sqlite
      direnv
      tcpdump
      vimv-rs
      openssl
      bsdgames
      headscale
      mailutils
      nixos-option
      graphicsmagick
    ];
  };

  services = {
    tailscale.enable = true;

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
    };

    zfs = {
      autoScrub.enable = true;
      trim.enable = true;
      expandOnBoot = "all";
    };

    openssh = {
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
      settings = {
        server_url = "https://vpn.jakstys.lt";
        ip_prefixes = [
          myData.tailscale_subnet.cidr
          "fd7a:115c:a1e0:59b0::/64"
        ];
        log.level = "warn";
        dns_config = {
          nameservers = ["1.1.1.1" "8.8.4.4"];
          magic_dns = true;
          base_domain = "jakst";
        };
        oidc = {
          issuer = "https://git.jakstys.lt/";
          client_id = "1c5fe796-452c-458d-b295-71a9967642fc";
          client_secret_path = "/var/lib/headscale/oidc_client_secret"; # TODO move to secrets
        };
      };
    };

    gitea = {
      enable = true;
      user = "git";
      database.user = "git";
      settings = {
        admin.DISABLE_REGULAR_ORG_CREATION = true;
        api.ENABLE_SWAGGER = false;
        mirror.ENABLED = false;
        other.SHOW_FOOTER_VERSION = false;
        packages.ENABLED = false;
        repository = {
          DEFAULT_REPO_UNITS = "repo.code,repo.releases";
          DISABLE_MIGRATIONS = true;
          DISABLE_STARS = true;
          ENABLE_PUSH_CREATE_USER = true;
        };
        security.LOGIN_REMEMBER_DAYS = 30;
        server = {
          ENABLE_GZIP = true;
          LANDING_PAGE = "/motiejus";
          ROOT_URL = "https://git.jakstys.lt";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3000;
          DOMAIN = "git.jakstys.lt";
        };
        service = {
          DISABLE_REGISTRATION = true;
          ENABLE_TIMETRACKING = false;
          ENABLE_USER_HEATMAP = false;
          SHOW_MILESTONES_DASHBOARD_PAGE = false;
          COOKIE_SECURE = true;
        };
        log.LEVEL = "Error";
        # TODO: does not work with 1.7.4, getting error
        # in the UI when testing the email sending workflow.
        #mailer = {
        #    ENABLED = true;
        #    MAILER_TYPE = "sendmail";
        #    FROM = "<noreply@jakstys.lt>";
        #    SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
        #};
        "service.explore".DISABLE_USERS_PAGE = true;
      };
    };

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      virtualHosts."recordrecap.jakstys.lt".extraConfig = ''
        reverse_proxy vno1-oh2.servers.jakst:8080
      '';
      virtualHosts."www.recordrecap.jakstys.lt".extraConfig = ''
        redir https://recordrecap.jakstys.lt
      '';
      virtualHosts."vpn.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:8080
      '';
      virtualHosts."git.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
      virtualHosts."turn.jakstys.lt".extraConfig = ''
        redir https://jakstys.lt
      '';
      virtualHosts."www.jakstys.lt".extraConfig = ''
        redir https://jakstys.lt
      '';
      virtualHosts."fwmine.jakstys.lt".extraConfig = ''
        reverse_proxy fwmine.motiejus.jakst:8080
      '';
      virtualHosts."jakstys.lt" = {
        logFormat = ''
          output file ${config.services.caddy.logDir}/access-jakstys.lt.log {
            roll_disabled
          }
        '';
        extraConfig = ''
          header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

          header /_/* Cache-Control "public, max-age=31536000, immutable"

          root * /var/www/jakstys.lt
          file_server {
            precompressed br gzip
          }

          @matrixMatch {
            path /.well-known/matrix/client
            path /.well-known/matrix/server
          }
          header @matrixMatch Content-Type application/json
          header @matrixMatch Access-Control-Allow-Origin *
          header @matrixMatch Cache-Control "public, max-age=3600, immutable"

          handle /.well-known/matrix/client {
            respond "{\"m.homeserver\": {\"base_url\": \"https://jakstys.lt\"}}" 200
          }
          handle /.well-known/matrix/server {
            respond "{\"m.server\": \"jakstys.lt:443\"}" 200
          }

          handle /_matrix/* {
            encode gzip
            reverse_proxy http://127.0.0.1:8008
          }
        '';
      };
    };

    coturn = {
      enable = true;
      min-port = 49152;
      max-port = 49999;
      no-tcp-relay = true;
      realm = "turn.jakstys.lt";
      cert = "/run/coturn/tls-cert.pem";
      pkey = "/run/coturn/tls-key.pem";
      static-auth-secret-file = "\${CREDENTIALS_DIRECTORY}/static-auth-secret";
      extraConfig = ''
        verbose
        no-multicast-peers
        denied-peer-ip=10.0.0.0-10.255.255.255
        denied-peer-ip=192.168.0.0-192.168.255.255
        denied-peer-ip=172.16.0.0-172.31.255.255
        denied-peer-ip=${myData.tailscale_subnet.range}
      '';
    };

    # TODO: app_service_config_files
    matrix-synapse = {
      enable = true;
      settings = {
        server_name = "jakstys.lt";
        admin_contact = "motiejus@jakstys.lt";
        enable_registration = false;
        report_stats = true;
        signing_key_path = "/run/matrix-synapse/jakstys_lt_signing_key";
        extraConfigFiles = ["/run/matrix-synapse/secrets.yaml"];
        log_config = pkgs.writeText "log.config" ''
          version: 1
          formatters:
            precise:
             format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
          handlers:
            console:
              class: logging.StreamHandler
              formatter: precise
          loggers:
              synapse.storage.SQL:
                  level: WARN
          root:
              level: ERROR
              handlers: [console]
          disable_existing_loggers: false
        '';
        public_baseurl = "https://jakstys.lt/";
        database.name = "sqlite3";
        url_preview_enabled = false;
        max_upload_size = "50M";
        turn_allow_guests = false;
        turn_uris = [
          "turn:turn.jakstys.lt:3487?transport=udp"
          "turn:turn.jakstys.lt:3487?transport=tcp"
          "turns:turn.jakstys.lt:5349?transport=udp"
          "turns:turn.jakstys.lt:5349?transport=tcp"
        ];
        rc_messages_per_second = 0.2;
        rc_message_burst_count = 10.0;
        federation_rc_window_size = 1000;
        federation_rc_sleep_limit = 10;
        federation_rc_sleep_delay = 500;
        federation_rc_reject_limit = 50;
        federation_rc_concurrent = 3;
        allow_profile_lookup_over_federation = false;
        thumbnail_sizes = [
          {
            width = 32;
            height = 32;
            method = "crop";
          }
          {
            width = 96;
            height = 96;
            method = "crop";
          }
          {
            width = 320;
            height = 240;
            method = "scale";
          }
          {
            width = 640;
            height = 480;
            method = "scale";
          }
          {
            width = 800;
            height = 600;
            method = "scale";
          }
        ];
        user_directory = {
          enabled = true;
          search_all_users = false;
          prefer_local_users = true;
        };
        allow_device_name_lookup_over_federation = false;
        email = {
          smtp_host = "127.0.0.1";
          smtp_port = 25;
          notf_for_new_users = false;
          notif_from = "Jakstys %(app)s homeserver <noreply@jakstys.lt>";
        };
        include_profile_data_on_invite = false;
        password_config.enabled = true;
        require_auth_for_profile_requests = true;
      };
    };

    postfix = {
      enable = true;
      enableSmtp = true;
      networks = [
        "127.0.0.1/8"
        "[::ffff:127.0.0.0]/104"
        "[::1]/128"
        myData.tailscale_subnet.cidr
      ];
      hostname = "${config.networking.hostName}.${config.networking.domain}";
      relayHost = "smtp.sendgrid.net";
      relayPort = 587;
      mapFiles = {
        sasl_passwd = config.age.secrets.sasl-passwd.path;
      };
      extraConfig = ''
        smtp_sasl_auth_enable = yes
        smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
        smtp_sasl_security_options = noanonymous
        smtp_sasl_tls_security_options = noanonymous
        smtp_tls_security_level = encrypt
        header_size_limit = 4096000
      '';
    };

    logrotate = {
      settings = {
        "/var/log/caddy/access-jakstys.lt.log" = {
          rotate = 60;
          frequency = "daily";
          dateext = true;
          dateyesterday = true;
          compress = true;
          compresscmd = "${pkgs.zstd}/bin/zstd";
          compressext = ".zst";
          compressoptions = "--long -19";
          uncompresscmd = "${pkgs.zstd}/bin/unzstd";
          postrotate = "${pkgs.systemd}/bin/systemctl restart caddy";
        };
      };
    };

    sshguard = {
      enable = true;
      blocktime = 900;
      whitelist = [
        "192.168.0.0/16"
        myData.tailscale_subnet.cidr
        myData.ips.vno1
      ];
    };
  };

  networking = {
    hostName = "hel1-a";
    domain = "jakstys.lt";
    firewall = let
      coturn = with config.services.coturn; [
        {
          from = min-port;
          to = max-port;
        }
      ];
    in {
      allowedTCPPorts = [
        53
        80
        443
        3478 # turn/headscale
        5349 # turn
        5350 # turn
      ];
      allowedUDPPorts = [
        53
        443
        3478 # turn
        41641 # tailscale
      ];
      allowedUDPPortRanges = coturn;
      logRefusedConnections = false;
      checkReversePath = "loose"; # for tailscale
    };
  };

  system = {
    # TODO: run the upgrades after the backup service is complete
    autoUpgrade.enable = true;
    autoUpgrade = {
      allowReboot = true;
      dates = "01:00";
      rebootWindow = {
        lower = "01:00";
        upper = "03:00";
      };
    };
  };

  nix = {
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 14d";
    };
    extraOptions = ''
      experimental-features = nix-command flakes
      trusted-users = motiejus
    '';
  };

  systemd.tmpfiles.rules = [
    "d /run/matrix-synapse 0700 matrix-synapse matrix-synapse -"
  ];

  systemd.services =
    {
      coturn = {
        preStart = ''
          ln -sf ''${CREDENTIALS_DIRECTORY}/tls-key.pem /run/coturn/tls-key.pem
          ln -sf ''${CREDENTIALS_DIRECTORY}/tls-cert.pem /run/coturn/tls-cert.pem
        '';
        unitConfig.ConditionPathExists = [
          "${turn_cert_dir}/turn.jakstys.lt.key"
          "${turn_cert_dir}/turn.jakstys.lt.crt"
        ];
        serviceConfig.LoadCredential = [
          "static-auth-secret:${config.age.secrets.turn-static-auth-secret.path}"
          "tls-key.pem:${turn_cert_dir}/turn.jakstys.lt.key"
          "tls-cert.pem:${turn_cert_dir}/turn.jakstys.lt.crt"
        ];
      };

      headscale = {
        unitConfig.StartLimitIntervalSec = "5m";

        # Allow restarts for up to a minute. A start
        # itself may take a while, thus the window of restart
        # is higher.
        unitConfig.StartLimitBurst = 50;
        serviceConfig.RestartSec = 1;
      };

      matrix-synapse = let
        # TODO https://github.com/NixOS/nixpkgs/pull/222336 replace with `preStart`
        secretsScript = pkgs.writeShellScript "write-secrets" ''
          set -euo pipefail
          umask 077
          ln -sf ''${CREDENTIALS_DIRECTORY}/jakstys_lt_signing_key /run/matrix-synapse/jakstys_lt_signing_key
          cat > /run/matrix-synapse/secrets.yaml <<EOF
          registration_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/registration_shared_secret)"
          macaroon_secret_key: "$(cat ''${CREDENTIALS_DIRECTORY}/macaroon_secret_key)"
          turn_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/turn_shared_secret)"
          EOF
        '';
      in {
        serviceConfig.ExecStartPre = ["" secretsScript];
        serviceConfig.LoadCredential = [
          "jakstys_lt_signing_key:${config.age.secrets.synapse-jakstys-signing-key.path}"
          "registration_shared_secret:${config.age.secrets.synapse-registration-shared-secret.path}"
          "macaroon_secret_key:${config.age.secrets.synapse-macaroon-secret-key.path}"
          "turn_shared_secret:${config.age.secrets.turn-static-auth-secret.path}"
        ];
      };

      cert-watcher = {
        description = "Restart coturn when tls key/cert changes";
        wantedBy = ["multi-user.target"];
        unitConfig = {
          StartLimitIntervalSec = 10;
          StartLimitBurst = 5;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart coturn.service";
        };
      };

      zfs-scrub.unitConfig.OnFailure = "unit-status-mail@zfs-scrub.service";
      nixos-upgrade.unitConfig.OnFailure = "unit-status-mail@nixos-upgrade.service";
    }
    // lib.mapAttrs' (name: value: {
      name = "borgbackup-job-${name}";
      value = {
        unitConfig.OnFailure = "unit-status-mail@borgbackup-job-${name}.service";
      };
    })
    backup_paths;

  systemd.paths = {
    cert-watcher = {
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = "${turn_cert_dir}/turn.jakstys.lt.crt";
        Unit = "cert-watcher.service";
      };
    };
  };
}

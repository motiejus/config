{
  config,
  pkgs,
  lib,
  agenix,
  myData,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./zfs.nix
  ];

  mj = {
    stateVersion = "22.11";
    timeZone = "UTC";

    base = {
      zfs.enable = true;

      users.passwd = {
        root.passwordFile = config.age.secrets.root-passwd-hash.path;
        motiejus.passwordFile = config.age.secrets.motiejus-passwd-hash.path;
      };

      initrd = {
        enable = true;
        authorizedKeys =
          (builtins.attrValues myData.people_pubkeys)
          ++ [myData.hosts."vno1-oh2.servers.jakst".publicKey];
        hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
      };
      snapshot = {
        enable = true;
        mountpoints = ["/var/lib" "/var/log"];
      };

      zfsborg = {
        enable = true;
        passwordPath = config.age.secrets.borgbackup-password.path;
        mountpoints = {
          "/var/lib" = {
            repo = "zh2769@zh2769.rsync.net:hel1-a.servers.jakst-var_lib";
            paths = [
              "/var/lib/.snapshot-latest/gitea"
              "/var/lib/.snapshot-latest/headscale"
              "/var/lib/.snapshot-latest/matrix-synapse"
            ];
            backup_at = "*-*-* 00:05:00";
          };
          "/var/log" = {
            repo = "zh2769@zh2769.rsync.net:hel1-a.servers.jakst-var_log";
            paths = ["/var/log/.snapshot-latest/caddy/"];
            patterns = [
              "+ /var/log/.snapshot-latest/caddy/access-jakstys.lt.log-*.zst"
              "- *"
            ];
            backup_at = "*-*-* 00:01:00";
          };
        };
      };

      unitstatus = {
        enable = true;
        email = "motiejus+alerts@jakstys.lt";
      };
    };

    services = {
      node_exporter.enable = true;

      gitea.enable = true;

      deployerbot = {
        follower = {
          enable = true;
          uidgid = myData.uidgid.updaterbot-deployee;
          publicKey = myData.hosts."vno1-oh2.servers.jakst".publicKey;
        };
      };
      postfix = {
        enable = true;
        saslPasswdPath = config.age.secrets.sasl-passwd.path;
      };

      zfsunlock = {
        enable = true;
        targets."vno1-oh2.servers.jakst" = let
          host = myData.hosts."vno1-oh2.servers.jakst";
        in {
          sshEndpoint = host.publicIP;
          pingEndpoint = host.jakstIP;
          remotePubkey = host.initrdPubKey;
          pwFile = config.age.secrets.zfs-passphrase-vno1-oh2.path;
          startAt = "*-*-* *:00/5:00";
        };
      };
    };
  };

  environment.systemPackages = with pkgs; [
    headscale
    nixos-option
    graphicsmagick
  ];

  services = {
    tailscale.enable = true;

    nsd = {
      enable = true;
      interfaces = ["0.0.0.0" "::"];
      zones = {
        "jakstys.lt.".data = myData.jakstysLTZone;
      };
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
          magic_dns = false;
          base_domain = "jakst";
        };
        oidc = {
          issuer = "https://git.jakstys.lt/";
          client_id = "e25c15ea-41ca-4bf0-9ebf-2be9f2d1ccea";
          # TODO https://github.com/NixOS/nixpkgs/pull/249101/files
          #client_secret_path = "\${CREDENTIALS_DIRECTORY}/oidc-client-secret";
          client_secret_path = "/run/credentials/headscale.service/oidc-client-secret";
        };
      };
    };

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
      virtualHosts."recordrecap.jakstys.lt".extraConfig = ''
        reverse_proxy vno1-oh2.servers.jakst:8080
      '';
      virtualHosts."vpn.jakstys.lt".extraConfig = ''
        reverse_proxy 127.0.0.1:8080
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
  };

  networking = {
    hostName = "hel1-a";
    domain = "servers.jakst";
    firewall = {
      allowedTCPPorts = [
        53
        80
        443
        3478 # headscale
      ];
      allowedUDPPorts = [
        53
        443
        3478 # headscale
        41641 # tailscale
      ];
      logRefusedConnections = false;
      checkReversePath = "loose"; # for tailscale
    };
  };

  systemd.tmpfiles.rules = [
    "d /run/matrix-synapse 0700 matrix-synapse matrix-synapse -"
  ];

  systemd.services = {
    headscale = {
      unitConfig.StartLimitIntervalSec = "5m";

      # Allow restarts for up to a minute. A start
      # itself may take a while, thus the window of restart
      # is higher.
      unitConfig.StartLimitBurst = 50;
      serviceConfig.RestartSec = 1;
      serviceConfig.LoadCredential = [
        "oidc-client-secret:${config.age.secrets.headscale-client-oidc.path}"
      ];
    };

    matrix-synapse = let
      # TODO https://github.com/NixOS/nixpkgs/pull/222336 replace with `preStart`
      secretsScript = pkgs.writeShellScript "write-secrets" ''
        set -xeuo pipefail
        umask 077
        ln -sf ''${CREDENTIALS_DIRECTORY}/jakstys_lt_signing_key /run/matrix-synapse/jakstys_lt_signing_key
        cat > /run/matrix-synapse/secrets.yaml <<EOF
        registration_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/registration_shared_secret)"
        macaroon_secret_key: "$(cat ''${CREDENTIALS_DIRECTORY}/macaroon_secret_key)"
        EOF
      '';
    in {
      serviceConfig.ExecStartPre = ["" secretsScript];
      serviceConfig.LoadCredential = [
        "jakstys_lt_signing_key:${config.age.secrets.synapse-jakstys-signing-key.path}"
        "registration_shared_secret:${config.age.secrets.synapse-registration-shared-secret.path}"
        "macaroon_secret_key:${config.age.secrets.synapse-macaroon-secret-key.path}"
      ];
    };
  };
}

{
  config,
  pkgs,
  lib,
  ...
}: let
  gitea_uidgid = 995;

  tailscale_subnet = {
    cidr = "100.89.176.0/20";
    range = "100.89.176.0-100.89.191.255";
  };

  ips = {
    vno1 = "88.223.107.21";
    hel1a = "65.21.7.119";
  };

  ssh_pubkeys = {
    motiejus = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+qpaaD+FCYPcUU1ONbw/ff5j0xXu5DNvp/4qZH/vOYwG13uDdfI5ISYPs8zNaVcFuEDgNxWorVPwDw4p6+1JwRLlhO4J/5tE1w8Gt6C7y76LRWnp0rCdva5vL3xMozxYIWVOAiN131eyirV2FdOaqTwPy4ouNMmBFbibLQwBna89tbFMG/jwR7Cxt1I6UiYOuCXIocI5YUbXlsXoK9gr5yBRoTjl2OfH2itGYHz9xQCswvatmqrnteubAbkb6IUFYz184rnlVntuZLwzM99ezcG4v8/485gWkotTkOgQIrGNKgOA7UNKpQNbrwdPAMugqfSTo6g8fEvy0Q+6OXdxw5X7en2TJE+BLVaXp4pVMdOAzKF0nnssn64sRhsrUtFIjNGmOWBOR2gGokaJcM6x9R72qxucuG5054pSibs32BkPEg6Qzp+Bh77C3vUmC94YLVg6pazHhLroYSP1xQjfOvXyLxXB1s9rwJcO+s4kqmInft2weyhfaFE0Bjcoc+1/dKuQYfPCPSB//4zvktxTXud80zwWzMy91Q4ucRrHTBz3PrhO8ys74aSGnKOiG3ccD3HbaT0Ff4qmtIwHcAjrnNlINAcH/A2mpi0/2xA7T8WpFnvgtkQbcMF0kEKGnNS5ULZXP/LC8BlLXxwPdqTzvKikkTb661j4PhJhinhVwnQ==";
    vno1_root = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMiWb7yeSeuFCMZWarKJD6ZSxIlpEHbU++MfpOIy/2kh";
  };

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

  nixpkgs.overlays = [
    (self: super: {
      systemd = super.systemd.overrideAttrs (old: {
        patches =
          (old.patches or [])
          ++ [
            (super.fetchpatch {
              url = "https://github.com/systemd/systemd/commit/e7f64b896201da4a11da158c35865604cf02062f.patch";
              sha256 = "sha256-AvBkrD9n5ux1o167yKg1eJK8C300vBS/ks3Gbvy5vjw=";
            })
          ];
      });
    })
  ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      authorizedKeys = builtins.attrValues ssh_pubkeys;
      hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
    };
  };

  security = {
    sudo = {
      wheelNeedsPassword = false;
      execWheelOnly = true;
    };
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
        uid = gitea_uidgid;
      };

      motiejus = {
        isNormalUser = true;
        extraGroups = ["wheel"];
        uid = 1000;
        openssh.authorizedKeys.keys = [ssh_pubkeys.motiejus];
      };
    };

    groups.gitea.gid = gitea_uidgid;
  };

  environment = {
    systemPackages = with pkgs; [
      jq
      git
      dig
      wget
      tree
      lsof
      file
      tmux
      htop
      rage
      #ncdu
      nmap
      ipset
      p7zip
      pwgen
      parted
      sqlite
      direnv
      vimv-rs
      openssl
      ripgrep
      bsdgames
      binutils
      moreutils
      headscale
      mailutils
      nixos-option
      unixtools.xxd
      graphicsmagick
    ];
    variables = {
      EDITOR = "nvim";
    };
  };

  programs = {
    mtr.enable = true;
    mosh.enable = true;
    neovim = {
      enable = true;
      defaultEditor = true;
    };

    ssh.knownHosts = {
      "vno1-oh2.servers.jakst" = {
        extraHostNames = ["dl.jakstys.lt" "vno1-oh2.jakstys.lt"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHtYsaht57g2sp6UmLHqsCK+fHjiiZ0rmGceFmFt88pY";
      };
      "hel1-a.servers.jakst" = {
        extraHostNames = ["hel1-a.jakstys.lt" "git.jakstys.lt" "vpn.jakstys.lt" "jakstys.lt" "www.jakstys.lt"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6Wd2lKrpP2Gqul10obMo2dc1xKaaLv0I4FAnfIaFKu";
      };
      "mtwork.motiejus.jakst" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOvNuABV5KXmh6rmS+R50XeJ9/V+Sgpuc1DrlYXW2bQb";
      };
      "zh2769.rsync.net" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
      };
      "github.com" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };
      "git.sr.ht" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZvRd4EtM7R+IHVMWmDkVU3VLQTSwQDSAvW0t2Tkj60";
      };
    };
  };

  services = {
    tailscale.enable = true;

    zfs = {
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

    sanoid = {
      enable = true;
      templates.prod = {
        hourly = 24;
        daily = 7;
        autosnap = true;
        autoprune = true;
      };
      datasets =
        lib.mapAttrs' (name: value: {
          name = value.zfs_name;
          value = {use_template = ["prod"];};
        })
        backup_paths;
      extraArgs = ["--verbose"];
    };

    borgbackup.jobs =
      lib.mapAttrs' (name: value: let
        snapshot = {
          mountpoint = value.mountpoint;
          zfs_name = value.zfs_name;
        };
        rwpath = value.mountpoint + "/.snapshot-latest";
      in {
        name = name;
        value =
          {
            doInit = true;
            repo = "zh2769@zh2769.rsync.net:hel1-a.servers.jakst";
            encryption = {
              mode = "repokey-blake2";
              passCommand = "cat /var/src/secrets/borgbackup/password";
            };
            paths = value.paths;
            extraArgs = "--remote-path=borg1";
            compression = "auto,lzma";
            startAt = value.backup_at;
            readWritePaths = [rwpath];
            preHook = mountLatest snapshot;
            postHook = umountLatest snapshot;
            prune.keep = {
              within = "1d";
              daily = 7;
              weekly = 4;
              monthly = 3;
            };
          }
          // lib.optionalAttrs (value ? patterns) {
            patterns = value.patterns;
          };
      })
      backup_paths;

    headscale = {
      enable = true;
      serverUrl = "https://vpn.jakstys.lt";
      openIdConnect = {
        issuer = "https://git.jakstys.lt/";
        clientId = "1c5fe796-452c-458d-b295-71a9967642fc";
        clientSecretFile = "/var/lib/headscale/oidc_client_secret"; # https://github.com/juanfont/headscale/pull/1127
      };
      logLevel = "warn";
      settings = {
        ip_prefixes = [
          tailscale_subnet.cidr
          "fd7a:115c:a1e0:59b0::/64"
        ];
        dns_config = {
          nameservers = ["1.1.1.1" "8.8.4.4"];
          magic_dns = true;
          base_domain = "jakst";
        };
      };
    };

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
        denied-peer-ip=${tailscale_subnet.range}
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
        signing_key_path = "/run/matrix-synapse/jakstys.lt.signing.key";
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
        tailscale_subnet.cidr
      ];
      hostname = "${config.networking.hostName}.${config.networking.domain}";
      relayHost = "smtp.sendgrid.net";
      relayPort = 587;
      mapFiles = {
        sasl_passwd = "/var/src/secrets/postfix/sasl_passwd";
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
        tailscale_subnet.cidr
        ips.vno1
      ];
    };

    knot = let
      jakstysLTZone = pkgs.writeText "jakstys.lt.zone" ''
        $ORIGIN jakstys.lt.
        $TTL 86400
        @             SOA   ns1.jakstys.lt. motiejus.jakstys.lt. (2023032100 86400 86400 86400 86400)
        @             NS    ns1.jakstys.lt.
        @             NS    ns2.jakstys.lt.
        @             A     ${ips.hel1a}
        www           A     ${ips.hel1a}
        ns1           A     ${ips.vno1}
        ns2           A     ${ips.hel1a}
        beta          A     ${ips.hel1a}
        turn          A     ${ips.hel1a}
        vpn           A     ${ips.hel1a}
        git           A     ${ips.hel1a}
        auth          A     ${ips.hel1a}
        dl            A     ${ips.vno1}
        hel1-a        A     ${ips.hel1a}
        vno1          A     ${ips.vno1}
        @             MX     10 aspmx.l.google.com.
        @             MX     20 alt1.aspmx.l.google.com.
        @             MX     20 alt2.aspmx.l.google.com.
        @             MX     30 aspmx2.googlemail.com.
        @             MX     30 aspmx3.googlemail.com.
      '';
    in {
      enable = true;
      extraConfig = ''
        server:
          listen: 0.0.0.0@53
          listen: ::@53
          version: 42
        zone:
          - domain: jakstys.lt
            file: ${jakstysLTZone}
            semantic-checks: on
      '';
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
      "make-snapshot-dirs" = let
        vals = builtins.attrValues backup_paths;
        mountpoints = builtins.catAttrs "mountpoint" vals;
        unique_mountpoints = lib.unique mountpoints;
      in {
        description = "prepare snapshot directories for backups";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = builtins.map (d: "${pkgs.coreutils}/bin/mkdir -p ${d}/.snapshot-latest") unique_mountpoints;
          RemainAfterExit = true;
        };
      };

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
          "static-auth-secret:/var/src/secrets/turn/static-auth-secret"
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
          ln -sf ''${CREDENTIALS_DIRECTORY}/jakstys.lt.signing.key /run/matrix-synapse/jakstys.lt.signing.key
          cat > /run/matrix-synapse/secrets.yaml <<EOF
          registration_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/registration_shared_secret)"
          macaroon_secret_key: "$(cat ''${CREDENTIALS_DIRECTORY}/macaroon_secret_key)"
          turn_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/turn_shared_secret)"
          EOF
        '';
      in {
        serviceConfig.ExecStartPre = ["" secretsScript];
        serviceConfig.LoadCredential = [
          "jakstys.lt.signing.key:/var/src/secrets/synapse/jakstys.lt.signing.key"
          "registration_shared_secret:/var/src/secrets/synapse/registration_shared_secret"
          "macaroon_secret_key:/var/src/secrets/synapse/macaroon_secret_key"
          "turn_shared_secret:/var/src/secrets/turn/static-auth-secret"
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

      # https://northernlightlabs.se/2014-07-05/systemd-status-mail-on-unit-failure.html
      "unit-status-mail@" = let
        script = pkgs.writeShellScript "unit-status-mail" ''
          set -e
          MAILTO="motiejus+alerts@jakstys.lt"
          UNIT=$1
          EXTRA=""
          for e in "''${@:2}"; do
            EXTRA+="$e"$'\n'
          done
          UNITSTATUS=$(${pkgs.systemd}/bin/systemctl status "$UNIT")
          ${pkgs.postfix}/bin/sendmail $MAILTO <<EOF
          Subject:Status mail for unit: $UNIT

          Status report for unit: $UNIT
          $EXTRA

          $UNITSTATUS
          EOF

          echo -e "Status mail sent to: $MAILTO for unit: $UNIT"
        '';
      in {
        description = "Send an email on unit failure";
        serviceConfig = {
          Type = "simple";
          ExecStart = ''${script} "%I" "Hostname: %H" "Machine ID: %m" "Boot ID: %b" '';
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

  # Do not change
  system.stateVersion = "22.11";
}

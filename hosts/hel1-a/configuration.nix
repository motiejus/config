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

      headscale = {
        enable = true;
        clientOidcPath = config.age.secrets.headscale-client-oidc.path;
        subnetCIDR = myData.tailscale_subnet.cidr;
      };

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

      matrix-synapse = {
        enable = true;
        signingKeyPath = config.age.secrets.synapse-jakstys-signing-key.path;
        registrationSharedSecretPath = config.age.secrets.synapse-registration-shared-secret.path;
        macaroonSecretKeyPath = config.age.secrets.synapse-macaroon-secret-key.path;
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

    caddy = {
      enable = true;
      email = "motiejus+acme@jakstys.lt";
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

    logrotate = {
      settings = {
        "/var/log/caddy/access-jakstys.lt.log" = {
          rotate = -1;
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
      ];
      allowedUDPPorts = [
        53
        443
        41641 # tailscale
      ];
      checkReversePath = "loose"; # for tailscale
    };
  };
}

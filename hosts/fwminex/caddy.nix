{
  pkgs,
  myData,
  ...
}:
{
  services.caddy = {
    enable = true;
    email = "motiejus+acme@jakstys.lt";
    globalConfig = ''
      grace_period 5s
      metrics {
        per_host
      }
    '';
    virtualHosts = {
      "jonas.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header Alt-Svc "h3=\":443\"; ma=86400"
        reverse_proxy vno3-nk:80
      '';
      "rolandas.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header Alt-Svc "h3=\":443\"; ma=86400"
        reverse_proxy vno3-nk:80
      '';
      "hass.jakstys.lt:80".extraConfig = ''
        @denied not remote_ip ${myData.subnets.tailscale.cidr}
        abort @denied
        reverse_proxy 127.0.0.1:${toString myData.ports.hass}
      '';
      "grafana.jakstys.lt".extraConfig = ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          header Alt-Svc "h3=\":443\"; ma=86400"
          reverse_proxy 127.0.0.1:${toString myData.ports.grafana}
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
      '';
      "bitwarden.jakstys.lt".extraConfig = ''
        @denied not remote_ip ${myData.subnets.tailscale.cidr}
        abort @denied
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem

        # from https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
        encode gzip
        header {
          # Enable HTTP Strict Transport Security (HSTS)
          Strict-Transport-Security "max-age=31536000;"
          # Enable cross-site filter (XSS) and tell browser to block detected attacks
          X-XSS-Protection "1; mode=block"
          # Disallow the site to be rendered within a frame (clickjacking protection)
          X-Frame-Options "SAMEORIGIN"
          Alt-Svc "h3=\":443\"; ma=86400"
        }

        reverse_proxy 127.0.0.1:${toString myData.ports.vaultwarden} {
           header_up X-Real-IP {remote_host}
        }
      '';
      "www.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        redir https://jakstys.lt
      '';
      "r1.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        redir https://r1.jakstys.lt:8443
      '';
      "up.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header Alt-Svc "h3=\":443\"; ma=86400"
        basic_auth {
          {$PLIK_USER} {$PLIK_PASSWORD}
        }
        reverse_proxy 127.0.0.1:${toString myData.ports.plik}
      '';
      "irc.jakstys.lt".extraConfig =
        let
          gamja = pkgs.compressDrvWeb (pkgs.gamja.override {
            gamjaConfig = {
              server = {
                url = "irc.jakstys.lt:6698";
                nick = "motiejus";
              };
            };
          }) { };
        in
        ''
          @denied not remote_ip ${myData.subnets.tailscale.cidr}
          abort @denied
          tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
          header Alt-Svc "h3=\":443\"; ma=86400"

          root * ${gamja}
          file_server browse {
              precompressed zstd br gzip
          }
        '';
      "r.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        redir https://rita.jakstys.lt{uri} 301
      '';
      "rita.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header Alt-Svc "h3=\":443\"; ma=86400"
        root * /var/www/rita.jakstys.lt
        file_server {
          precompressed zstd br gzip
        }
      '';
      "dl.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header Alt-Svc "h3=\":443\"; ma=86400"
        root * /var/www/dl
        file_server browse {
          hide .stfolder
        }
        encode gzip
      '';
      "m.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
        header {
          Strict-Transport-Security "max-age=15768000"
          Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'"
          X-Content-Type-Options "nosniff"
          X-Frame-Options "DENY"
          Alt-Svc "h3=\":443\"; ma=86400"
          /_/* Cache-Control "public, max-age=31536000, immutable"
        }

        root * /var/www/m.jakstys.lt
        file_server {
          precompressed zstd br gzip
        }
      '';
      "jakstys.lt".extraConfig =
        let
          jakstysLandingPage =
            pkgs.runCommand "jakstys-landing-page"
              {
                nativeBuildInputs = with pkgs; [
                  zstd
                  brotli
                  zopfli
                ];
              }
              ''
                mkdir -p $out
                cp ${../../jakstys.lt/index.html} $out/index.html
                cp ${../../jakstys.lt/robots.txt} $out/robots.txt
                cp ${../../jakstys.lt/robots.txt} $out/googlebfa9b278b6db80a4.html
                OUTS=(index.html robots.txt googlebfa9b278b6db80a4.html)
                for outfile in "''${OUTS[@]}"; do
                  zstd -k -19 "$out/$outfile"
                  brotli -k "$out/$outfile"
                  zopfli -k "$out/$outfile"
                done
              '';
        in
        ''
          tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem
          @redirects {
            path /2022/big-tech-hiring/
            path /2022/first-post-here/
            path /2022/how-uber-uses-zig/
            path /2022/my-favorite-podcast/
            path /2022/side-project-retrospective/
            path /2022/smart-bundling/
            path /2022/synctech.html
            path /2022/startup/
            path /2022/uber-mock-interview-retrospective/
            path /2023/7-years-at-uber/
            path /2023/end-of-summer-2023/
            path /2023/microsoft-git/
            path /2023/my-declining-matrix-usage/
            path /2023/my-zig-and-go-work-for-the-next-3-months/
            path /2023/nixos-subjectively/
            path /2023/summer-roadmap-2023/
            path /2024/11sync-shutdown/
            path /2024/11sync-signup/
            path /2024/bcachefs/
            path /2024/family-single-sign-on-was-a-bad-idea/
            path /2024/i-have-successfully-re-googled-myself/
            path /2024/new-job/
            path /2024/thank-you-drew-devault/
            path /2024/web-compression/
            path /2024/zig-reproduced-without-binaries/
            path /2025/construction-site-surveillance/
            path /2026/testing-lifepo4-15ah-with-gyrfalcon-s8000/
            path /contact/
            path /gpg.txt
            path /log/rss.xml
            path /resume/
            path /resume.pdf
            path /talks/
            path /talks/2016-buildstuff-understanding-building-your-own-docker.mkv
            path /talks/2016-buildstuff-understanding-building-your-own-docker.pdf
            path /talks/2022-zig-milan-party_How-zig-is-used-at-Uber.pdf
            path /talks/2022-zig-milan-party_How-zig-is-used-at-Uber.webm
            path /talks/2024-sycl-maps-and-yellow-pages.mkv
            path /talks/2024-sycl-maps-and-yellow-pages.pdf
          }

          header {
            Strict-Transport-Security "max-age=15768000"
            Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Alt-Svc "h3=\":443\"; ma=86400"

            /_/* Cache-Control "public, max-age=31536000, immutable"
          }

          root * ${jakstysLandingPage}
          file_server {
            precompressed zstd br gzip
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
            reverse_proxy http://127.0.0.1:${toString myData.ports.matrix-synapse}
          }

          redir @redirects https://m.jakstys.lt{uri} 302
        '';
    };
  };
}

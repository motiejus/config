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
      # The map/search site is the content-addressed publisher tree
      # (search-design.md §4.1). Caddy serves ONLY the atomically switched
      # `current` symlink; it never writes into the object store and receives
      # read/execute only after the publisher's atomic rename. All naming,
      # hashing and validation are done by mapgames-publisher; Caddy applies the
      # cache/Range/CSP delivery policy.
      "maps.jakstys.lt".extraConfig = ''
        tls /run/caddy/jakstys.lt-cert.pem /run/caddy/jakstys.lt-key.pem

        root * /var/lib/mapgames/current

        header {
          Strict-Transport-Security "max-age=15768000"
          # The narrow 'wasm-unsafe-eval' addition lets the search Wasm module
          # instantiate; no 'unsafe-eval' and no remote script origin.
          Content-Security-Policy "default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; worker-src 'self'"
          X-Content-Type-Options "nosniff"
          X-Frame-Options "DENY"
          Referrer-Policy "no-referrer"
          Alt-Svc "h3=\":443\"; ma=86400"
        }

        # Every hash-named immutable object: one-year public immutable cache.
        @immutable path /app/objects/* /search/objects/* /map/objects/*
        header @immutable Cache-Control "public, max-age=31536000, immutable"

        # Identity-only formats (§4.1): PMTiles/MGA/MGG are byte-Range fetched by
        # the client and MUST always be delivered identity. This is enforced by a
        # MATCHER, never by the mere absence of a `.br` sibling: with a shared
        # object store, a stray or hostile `catalog-<h>.pmtiles.br` next to the
        # object would otherwise make the catch-all `precompressed br` answer a
        # Range request with `Content-Encoding: br` over the COMPRESSED file —
        # garbage to a PMTiles reader, and cached immutable for a year. They also
        # never negotiate, so they must not advertise `Vary: Accept-Encoding`.
        @identityOnly path *.pmtiles *.mga *.mgg
        header @identityOnly -Vary

        # index.html is the sole mutable URL: no-store, no validator, so it can
        # never return a validator-based 304. The request validators are
        # stripped so file_server cannot short-circuit to Not-Modified, and the
        # ETag/Last-Modified responses are suppressed. Every REPRESENTATION of
        # the page (`/`, `/index.html`, `/index.html.br`) is routed here, so the
        # `.br` page is negotiated through the same rewrite and inherits exactly
        # the same no-store/validator-free policy instead of being served as a
        # separate, cacheable, ETag-carrying URL.
        @index path / /index.html /index.html.br
        handle @index {
          request_header -If-None-Match
          request_header -If-Modified-Since
          header Cache-Control "no-store"
          header -Etag
          header -Last-Modified
          rewrite * /index.html
          file_server {
            precompressed br
          }
        }

        # The build manifest and the registry anchor are publisher state, not
        # site content. The publisher keeps them under `state/` (outside the
        # served root); this is the belt-and-braces refusal.
        @private path /web-graph.json /release-manifest.json
        handle @private {
          respond 404
        }

        # Identity-only objects: plain file_server, no precompression, so a
        # sibling `.br` can never be selected and no `Vary` is emitted. Byte
        # Range/206 is served from the RAW file.
        handle @identityOnly {
          file_server
        }

        # Everything else: raw+Brotli negotiation for the allowlisted objects
        # (Caddy adds `Content-Encoding: br` + `Vary: Accept-Encoding` only when
        # a `.br` sibling exists). No zstd/gzip precompression and no `.etag`
        # sidecars participate.
        handle {
          file_server {
            precompressed br
          }
        }
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

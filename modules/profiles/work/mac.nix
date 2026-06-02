{ pkgs, ... }:
let
  pacFile = pkgs.writeText "proxy.pac" ''
    function FindProxyForURL(url, host) {
        if (host === "go" || host === "go.") {
            return "PROXY 127.0.0.1:80";
        }
        return "DIRECT";
    }
  '';

  nginxGoConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    pid /var/run/nginx.pid;
    error_log /var/log/nginx/error.log;

    events {}

    http {
      access_log /var/log/nginx/access.log;

      server {
        listen 80 default_server;
        location = /proxy.pac {
          default_type application/x-ns-proxy-autoconfig;
          alias ${pacFile};
        }
      }

      server {
        listen 80;
        server_name go go.;
        location / {
          return 301 https://golinks.io$request_uri;
        }
      }

      server {
        listen 443 ssl;
        server_name go go.;
        ssl_certificate ${../../../shared/certs/go.pem};
        ssl_certificate_key ${../../../shared/certs/go.key};
        location / {
          return 301 https://golinks.io$request_uri;
        }
      }
    }
  '';
in
{
  imports = [ ./. ];

  environment.etc.hosts.text = ''
    127.0.0.1 localhost
    255.255.255.255 broadcasthost
    ::1 localhost
    127.0.0.1 go go.
  '';

  launchd.daemons.nginx = {
    script = ''
      mkdir -p /var/log/nginx
      ${pkgs.nginx}/bin/nginx -c ${nginxGoConf}
    '';
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
    };
  };

  system.activationScripts.postActivation.text = ''
    /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r svc; do
      /usr/sbin/networksetup -setautoproxyurl "$svc" "http://127.0.0.1/proxy.pac" 2>/dev/null || true
    done
  '';
}

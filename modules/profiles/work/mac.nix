{ pkgs, ... }:
let
  nginxGoConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    pid /var/run/nginx.pid;
    error_log /var/log/nginx/error.log;

    events {}

    http {
      access_log /var/log/nginx/access.log;

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
}

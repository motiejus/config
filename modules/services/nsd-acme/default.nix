{
  config,
  lib,
  pkgs,
  ...
}: let
  mkHook = zone: let
    rc = config.services.nsd.remoteControl;
    fullZone = "_acme-endpoint.${zone}";
    nsdconf = ''"$RUNTIME_DIRECTORY"/nsd.conf'';
  in
    pkgs.writeShellScript "nsd-acme-hook" ''
      set -euo pipefail
      METHOD=$1
      TYPE=$2
      AUTH=$5
      NOW=$(date +%y%m%d%H%M)
      DIR="/var/lib/nsd/zones"

      sed \
        -e "s~${rc.controlKeyFile}~$CREDENTIALS_DIRECTORY/nsd_control.key~" \
        -e "s~${rc.controlCertFile}~$CREDENTIALS_DIRECTORY/nsd_control.pem~" \
        -e "s~${rc.serverKeyFile}~$CREDENTIALS_DIRECTORY/nsd_server.key~" \
        -e "s~${rc.serverCertFile}~$CREDENTIALS_DIRECTORY/nsd_server.pem~" \
        /etc/nsd/nsd.conf > ${nsdconf}

      [ "$TYPE" != "dns-01" ] && { echo "Skipping $TYPE"; exit 1; }

      write_zone() {
          cat <<EOF
      \$ORIGIN ${fullZone}.
      \$TTL 60
      @      SOA   ${fullZone}. motiejus.jakstys.lt. ($NOW 12h 2h 2w 1h)
      @      TXT   $AUTH
      EOF
      }

      cleanup() {
          nsd-control delzone ${fullZone}
          rm -f "$DIR/${fullZone}.acme"
      }

      case "$METHOD" in
          begin)
              echo "Deleting previous ${fullZone} if exists ..."
              nsd-control -c ${nsdconf} delzone ${fullZone} || :
              write_zone > "$DIR/${fullZone}.acme"

              echo "Activating ${fullZone}"
              nsd-control -c ${nsdconf} addzone ${fullZone} acme
              ;;
          done)
              echo "ACME request successful, cleaning up"
              cleanup
              ;;
          failed)
              echo "ACME request failed, cleaning up"
              cleanup
              ;;
      esac
    '';
in {
  options.mj.services.nsd-acme = with lib.types; {
    enable = lib.mkEnableOption "enable acme certs via nsd";

    zones = lib.mkOption {
      default = {};
      type = attrsOf (submodule (
        {...}: {
          options = {
            accountKey = lib.mkOption {type = path;};
            days = lib.mkOption {
              type = int;
              default = 30;
            };
            staging = lib.mkOption {
              type = bool;
              default = false;
            };
          };
        }
      ));
    };
  };

  # TODO assert services.nsd.enable
  config = lib.mkIf config.mj.services.nsd-acme.enable {
    services.nsd.remoteControl.enable = true;
    services.nsd.extraConfig = ''
      pattern:
        name: "acme"
        zonefile: "/var/lib/nsd/zones/%s.acme"
    '';

    systemd.services =
      {
        nsd-control-setup = {
          requiredBy = ["nsd.service"];
          before = ["nsd.service"];
          unitConfig.ConditionPathExists = let
            rc = config.services.nsd.remoteControl;
          in [
            "|!${rc.controlKeyFile}"
            "|!${rc.controlCertFile}"
            "|!${rc.serverKeyFile}"
            "|!${rc.serverCertFile}"
          ];
          serviceConfig = {
            Type = "oneshot";
            UMask = 0077;
            ExecStart = "${pkgs.nsd}/bin/nsd-control-setup";
          };
          path = [pkgs.openssl];
        };
      }
      // lib.mapAttrs'
      (
        zone: cfg: let
          sanitized = lib.strings.sanitizeDerivationName zone;
        in
          lib.nameValuePair "nsd-acme-${sanitized}" {
            description = "dns-01 acme update for ${zone}";
            path = [pkgs.openssh pkgs.nsd];
            preStart = ''
              mkdir -p "$STATE_DIRECTORY/private"
              ln -sf "$CREDENTIALS_DIRECTORY/letsenctypt-account.key" \
                "$STATE_DIRECTORY/private/key.pem"
            '';
            serviceConfig = {
              ExecStart = let
                hook = mkHook zone;
                days = "--days ${builtins.toString cfg.days}";
                staging =
                  if cfg.staging
                  then "--staging"
                  else "";
              in "${pkgs.uacme} --verbose --days ${days} --hook ${hook} ${staging} issue ${zone}";
              DynamicUser = "yes";
              StateDirectory = "nsd-acme/${sanitized}";
              RuntimeDirectory = "nsd-acme/${sanitized}";
              LoadCredential = let
                rc = config.services.nsd.remoteControl;
              in [
                "nsd_control.key:${rc.controlKeyFile}"
                "nsd_control.pem:${rc.controlCertFile}"
                "nsd_server.key:${rc.serverKeyFile}"
                "nsd_server.pem:${rc.serverCertFile}"
                "letsencrypt-account.key:${cfg.accountKey}"
              ];
            };
          }
      )
      config.mj.services.nsd-acme.zones;

    mj.base.unitstatus.units = lib.mkIf config.mj.base.unitstatus.enable ["nsd-control-setup"];
  };
}

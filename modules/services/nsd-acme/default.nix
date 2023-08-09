{
  config,
  lib,
  pkgs,
  ...
}: let
  mkHook = zone: let
    rc = config.services.nsd.remoteControl;
    fullZone = "_acme-endpoint.${zone}";
  in
    pkgs.writeShellScript "nsd-acme-hook" ''
      set -xeuo pipefail
      METHOD=$1
      TYPE=$2
      AUTH=$5
      NOW=$(date +%y%m%d%H%M)
      DIR="/var/lib/nsd/acmezones"

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
          rm -f "$DIR/${fullZone}.zone"
      }

      mkdir -p "$DIR"

      case "$METHOD" in
          begin)
              echo "Deleting previous ${fullZone} if exists ..."
              nsd-control delzone ${fullZone} || :
              write_zone > "$DIR/${fullZone}.zone"

              echo "Activating ${fullZone}"
              nsd-control addzone ${fullZone} acme
              ;;
          done)
              echo "ACME request successful, cleaning up"
              cleanup
              ;;
          failed)
              echo "ACME request failed, not cleaning up"
              #cleanup
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
        zonefile: "/var/lib/nsd/acmezones/%s.zone"
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/nsd/acmezones 0755 nsd nsd -"
    ];

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
          };
          script = ''
            ${pkgs.nsd}/bin/nsd-control-setup
            chown nsd:nsd /etc/nsd/nsd_{control,server}.{key,pem}
          '';
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
              mkdir -p "$STATE_DIRECTORY/${sanitized}/private"
              ln -sf "$CREDENTIALS_DIRECTORY/letsencrypt-account-key" \
                "$STATE_DIRECTORY/${sanitized}/private/key.pem"
            '';
            serviceConfig = {
              ExecStart = let
                hook = mkHook zone;
                days = builtins.toString cfg.days;
                staging =
                  if cfg.staging
                  then "--staging"
                  else "";
              in "${pkgs.uacme}/bin/uacme -c \${STATE_DIRECTORY} --verbose --days ${days} --hook ${hook} ${staging} issue ${zone}";

              UMask = "0022";
              User = "nsd";
              Group = "nsd";
              StateDirectory = "nsd-acme/${sanitized}";
              LoadCredential = ["letsencrypt-account-key:${cfg.accountKey}"];
              ReadWritePaths = ["/var/lib/nsd/acmezones"];

              # from nixos/modules/security/acme/default.nix
              ProtectSystem = "strict";
              PrivateTmp = true;
              CapabilityBoundingSet = [""];
              DevicePolicy = "closed";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              ProtectClock = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectControlGroups = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              ProcSubset = "pid";
              RemoveIPC = true;
              # "cannot get devices"
              #RestrictAddressFamilies = [
              #  "AF_INET"
              #  "AF_INET6"
              #];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SystemCallArchitectures = "native";
              SystemCallFilter = [
                # 1. allow a reasonable set of syscalls
                "@system-service @resources"
                # 2. and deny unreasonable ones
                "~@privileged"
                # 3. then allow the required subset within denied groups
                "@chown"
              ];
            };
          }
      )
      config.mj.services.nsd-acme.zones;

    mj.base.unitstatus.units = lib.mkIf config.mj.base.unitstatus.enable ["nsd-control-setup"];
  };
}

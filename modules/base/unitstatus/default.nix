{
  config,
  lib,
  pkgs,
  ...
}: {
  # TODO:
  # - accept unit names:
  #   - assert they exist
  #   - add 'systemd.<unit>.unitConfig.OnFailure' to point to this one.
  # - assert postfix is configured
  options.mj.base.unitstatus = with lib.types; {
    enable = lib.mkEnableOption "alert by email on unit failure";
    email = lib.mkOption {type = str;};
    #units = lib.mkOption {type = lisOf str;};
  };

  config =
    lib.mkIf config.mj.base.unitstatus.enable {
      systemd.services."unit-status-mail@" = let
        # https://northernlightlabs.se/2014-07-05/systemd-status-mail-on-unit-failure.html
        script = pkgs.writeShellScript "unit-status-mail" ''
          set -e
          MAILTO="${config.mj.base.unitstatus.email}"
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
    #};
    # See TODO above.
    #// {
    #  systemd.services =
    #    lib.listToAttrs
    #    (map (
    #        unit: {
    #          name = unit;
    #          value = {
    #            unitConfig = {OnFailure = "unit-status-mail@${unit}.service";};
    #          };
    #        }
    #      )
    #      config.mj.base.unitstatus.units);
    };
}

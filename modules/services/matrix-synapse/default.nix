{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.mj.services.matrix-synapse = with lib.types; {
    enable = lib.mkEnableOption "Enable matrix-synapse";
    signingKeyPath = lib.mkOption { type = path; };
    registrationSharedSecretPath = lib.mkOption { type = path; };
    macaroonSecretKeyPath = lib.mkOption { type = path; };
  };

  config = lib.mkIf config.mj.services.matrix-synapse.enable {
    services.matrix-synapse = {
      enable = true;
      extraConfigFiles = [ "/run/matrix-synapse/secrets.yaml" ];
      settings = {
        server_name = "jakstys.lt";
        admin_contact = "motiejus@jakstys.lt";
        enable_registration = false;
        report_stats = true;
        signing_key_path = "/run/matrix-synapse/jakstys_lt_signing_key";
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

    systemd.tmpfiles.rules = [ "d /run/matrix-synapse 0700 matrix-synapse matrix-synapse -" ];

    systemd.services = {
      matrix-synapse =
        let
          # I tried to move this to preStart, but it complains:
          #   Config is missing macaroon_secret_key
          secretsScript = pkgs.writeShellScript "write-secrets" ''
            set -xeuo pipefail
            umask 077
            ln -sf ''${CREDENTIALS_DIRECTORY}/jakstys_lt_signing_key /run/matrix-synapse/jakstys_lt_signing_key
            cat > /run/matrix-synapse/secrets.yaml <<EOF
            registration_shared_secret: "$(cat ''${CREDENTIALS_DIRECTORY}/registration_shared_secret)"
            macaroon_secret_key: "$(cat ''${CREDENTIALS_DIRECTORY}/macaroon_secret_key)"
            EOF
          '';
        in
        {
          serviceConfig.ExecStartPre = [
            ""
            secretsScript
          ];
          serviceConfig.LoadCredential = with config.mj.services.matrix-synapse; [
            "jakstys_lt_signing_key:${signingKeyPath}"
            "registration_shared_secret:${registrationSharedSecretPath}"
            "macaroon_secret_key:${macaroonSecretKeyPath}"
          ];
        };
    };
  };
}

{
  config,
  lib,
  ...
}: {
  options.mj.base.initrd = {
    enable = lib.mkEnableOption "Enable base initrd settings";

    hostKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "ssh private key for use in initrd.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = lib.mdDoc "Authorized keys for the root user on initrd.";
    };
  };

  config = lib.mkIf config.mj.base.initrd.enable {
    boot.initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        port = 22;
        authorizedKeys = config.mj.base.initrd.authorizedKeys;
        hostKeys = config.mj.base.initrd.hostKeys;
      };
      postCommands = ''
        tee -a /root/.profile >/dev/null <<EOF
        if zfs load-key rpool/nixos; then
           pkill zfs
        fi
        exit
        EOF'';
    };
    };
  };
}

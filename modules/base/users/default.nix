{
  config,
  lib,
  myData,
  ...
}: {
  options.mj.base.users = with lib.types; {
    passwd = lib.mkOption {
      type = attrsOf (submodule (
        {...}: {
          options = {
            passwordFile = lib.mkOption {
              type = nullOr path;
              default = null;
            };
            initialPassword = lib.mkOption {
              type = nullOr str;
              default = null;
            };
          };
        }
      ));
    };
  };

  config = {
    users = {
      mutableUsers = false;

      users = with config.mj.base.users; {
        motiejus =
          {
            isNormalUser = true;
            extraGroups = ["wheel"];
            uid = 1000;
            openssh.authorizedKeys.keys = [myData.ssh_pubkeys.motiejus];
          }
          // lib.filterAttrs (n: v: v != null) passwd.motiejus or {};

        root = assert lib.assertMsg (passwd ? root) "root password needs to be defined";
          lib.filterAttrs (n: v: v != null) passwd.root;
      };
    };
  };
}

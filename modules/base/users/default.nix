{
  config,
  lib,
  myData,
  #home-manager,
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

      users = let
        passwd = config.mj.base.users.passwd;
      in {
        motiejus =
          {
            isNormalUser = true;
            extraGroups = ["wheel"];
            uid = myData.uidgid.motiejus;
            openssh.authorizedKeys.keys = [myData.people_pubkeys.motiejus];
          }
          // lib.filterAttrs (n: v: v != null) passwd.motiejus or {};

        root = assert lib.assertMsg (passwd ? root) "root password needs to be defined";
          lib.filterAttrs (n: v: v != null) passwd.root;
      };
    };

    home-manager.users.motiejus = {pkgs, ...}: {
      home.stateVersion = "23.05";
      programs.direnv.enable = true;
      programs.git = {
        enable = true;
        userEmail = "motiejus@jakstys.lt";
        aliases.yolo = "commit --amend --no-edit -a";
        extraConfig = {
          rerere.enabled = true;
          pull.ff = "only";
          merge.conflictstyle = "diff3";
        };
      };
      programs.bash = {
        enable = true;
        shellAliases = {
          "l" = "echo -n ł | xclip -selection clipboard";
          "gp" = "${pkgs.git} remote | ${pkgs.parallel} --verbose git push";
        };
      };
    };
  };
}

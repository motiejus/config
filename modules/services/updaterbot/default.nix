{
  config,
  lib,
  ...
}: {
  options.mj.services.updaterbot = with lib.types; {
    enable = lib.mkEnableOption "Enable system updater";
    deployDerivations = lib.mkOption {type = listOf str;};
    uidgid = lib.mkOption {type = int;};
    repo = lib.mkOption {type = str;};
  };

  config = lib.mkIf config.mj.services.updaterbot.enable {
    users = {
      users = {
        # TODO: git config --global user.email updaterbot@jakstys.lt
        # TODO: ssh-keygen -t ed25519
        updaterbot = {
          description = "Dear Updaterbot";
          home = "/var/lib/updaterbot";
          useDefaultShell = true;
          group = "updaterbot";
          isSystemUser = true;
          createHome = true;
          uid = config.mj.services.updaterbot.uidgid;
        };
      };

      groups = {
        updaterbot.gid = config.mj.services.updaterbot.uidgid;
      };
    };

    nix.settings.trusted-users = ["updaterbot"];
  };
}

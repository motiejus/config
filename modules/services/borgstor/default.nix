{
  config,
  lib,
  myData,
  pkgs,
  ...
}:
{
  options.mj.services.borgstor = with lib.types; {
    enable = lib.mkEnableOption "Enable borg storage user";
    dataDir = lib.mkOption { type = path; };
    sshKeys = lib.mkOption { type = listOf str; };
  };

  config =
    with config.mj.services.borgstor;
    lib.mkIf enable {
      users.users.borgstor = {
        description = "Borg Storage";
        home = dataDir;
        shell = "/bin/sh";
        group = "borgstor";
        isSystemUser = true;
        createHome = false;
        uid = myData.uidgid.borgstor;
        openssh.authorizedKeys.keys = map (
          k: ''command="${pkgs.borgbackup}/bin/borg serve --restrict-to-path ${dataDir}",restrict ${k}''
        ) sshKeys;
      };

      users.groups.borgstor.gid = myData.uidgid.borgstor;
    };
}

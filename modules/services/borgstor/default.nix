{
  config,
  lib,
  myData,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.borgstor;
in
{
  options.mj.services.borgstor = with lib.types; {
    enable = lib.mkEnableOption "Enable borg storage user";
    dataDir = lib.mkOption { type = path; };
    sshKeys = lib.mkOption { type = listOf str; };
  };

  config = lib.mkIf cfg.enable {

    users.users.borgstor = {
      description = "Borg Storage";
      home = cfg.dataDir;
      shell = "/bin/sh";
      group = "borgstor";
      isSystemUser = true;
      createHome = true;
      uid = myData.uidgid.borgstor;
      openssh.authorizedKeys.keys = map (
        k: ''command="${pkgs.borgbackup}/bin/borg serve --restrict-to-path ${cfg.dataDir}",restrict ${k}''
      ) cfg.sshKeys;
    };

    users.groups.borgstor.gid = myData.uidgid.borgstor;

  };
}

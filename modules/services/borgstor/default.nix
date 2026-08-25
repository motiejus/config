{
  config,
  lib,
  myData,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.borgstor;
  readerServe = pkgs.callPackage ../../../pkgs/borg-reader-serve.nix {
    inherit (cfg) readerSnapshotRoot readerPasswordPath;
  };
in
{
  options.mj.services.borgstor = with lib.types; {
    enable = lib.mkEnableOption "Enable borg storage user";
    dataDir = lib.mkOption { type = path; };
    sshKeys = lib.mkOption { type = listOf str; };
    readerKeys = lib.mkOption {
      type = listOf str;
      default = [ ];
      description = "SSH keys allowed to use the Btrfs snapshot Borg reader.";
    };
    readerSnapshotRoot = lib.mkOption {
      type = path;
      default = "/data/.btrfs";
      description = "Root-owned, non-writable directory containing read-only Btrfs snapshots served to the Borg reader identity.";
    };
    readerPasswordPath = lib.mkOption {
      type = nullOr path;
      default = null;
      description = "Passphrase file inherited by Borg reader sessions on dedicated FD 3.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.readerKeys == [ ] || cfg.readerPasswordPath != null;
        message = "mj.services.borgstor.readerPasswordPath is required when readerKeys are configured";
      }
    ];

    users.users.borgstor = {
      description = "Borg Storage";
      home = cfg.dataDir;
      shell = "/bin/sh";
      group = "borgstor";
      isSystemUser = true;
      createHome = true;
      uid = myData.uidgid.borgstor;
      openssh.authorizedKeys.keys =
        map (
          k: ''command="${pkgs.borgbackup}/bin/borg serve --restrict-to-path ${cfg.dataDir}",restrict ${k}''
        ) cfg.sshKeys
        ++ map (k: ''command="${readerServe}/bin/borg-reader-serve",restrict ${k}'') cfg.readerKeys;
    };

    users.groups.borgstor.gid = myData.uidgid.borgstor;

    services.openssh.extraConfig = lib.mkIf (cfg.readerKeys != [ ]) (
      lib.mkAfter ''
        AcceptEnv BORG_REPO
      ''
    );
  };
}

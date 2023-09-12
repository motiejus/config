{
  config,
  lib,
  pkgs,
  myData,
  ...
}: {
  options.mj.services.jakstpub = with lib.types; {
    enable = lib.mkEnableOption "Enable jakstpub";
    dataDir = lib.mkOption {type = path;};
    # RequiresMountsFor is used by upstream, hacking with the unit
    requires = lib.mkOption {type = listOf str;};
    uidgid = lib.mkOption {type = int;};
  };

  config = with config.mj.services.jakstpub;
    lib.mkIf enable {
      services.samba = {
        # https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Standalone_Server
        enable = true;
        securityType = "user";
        enableNmbd = false;
        enableWinbindd = false;
        extraConfig = ''
          map to guest = Bad User
          log level = 1
          guest account = jakstpub
          server role = standalone server
        '';
        shares = {
          public = {
            path = dataDir;
            writeable = "yes";
            public = "yes";
            "guest ok" = "yes";
            "read only" = "no";
            "create mask" = "0666";
            "directory mask" = "0777";
            "force user" = "jakstpub";
            "force group" = "jakstpub";
          };
        };
      };

      services.samba-wsdd.enable = true;

      users.users.jakstpub = {
        description = "Jakstys Public";
        home = "/var/empty";
        useDefaultShell = true;
        group = "jakstpub";
        isSystemUser = true;
        createHome = false;
        uid = uidgid;
      };

      users.groups.jakstpub.gid = uidgid;

      systemd.services.samba-smbd = {
        unitConfig.Requires = requires;
      };

      mj.services.friendlyport.ports = [
        {
          subnets = with myData.subnets; [tailscale.cidr vno1.cidr];
          tcp = [
            139 # smbd
            445 # smbd
            5357 # wsdd
          ];
          udp = [3702]; # wsdd
        }
      ];
    };
}

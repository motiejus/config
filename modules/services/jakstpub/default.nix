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
        enable = true;
        securityType = "user";
        enableNmbd = true;
        enableWinbindd = false;
        extraConfig = ''
          map to guest = Bad User
          guest account = jakstpub
        '';
        shares = {
          public = {
            path = dataDir;
            writable = "yes";
            printable = "no";
            public = "yes";
          };
        };
      };

      users.users.jakstpub = {
        description = "Jakstys Public";
        home = dataDir;
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

      mj.services.friendlyport.ports = [{
        subnets = with myData.subnets; [tailscale.cidr vno1.cidr];
        tcp = [ 139 445 ];
        udp = [ 137 138 ];
      }];
    };
}

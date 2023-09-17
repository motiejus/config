{
  config,
  lib,
  pkgs,
  myData,
  ...
}: let
  cfg = config.mj.services.jakstpub;
  subnets = myData.subnets;
in {
  options.mj.services.jakstpub = with lib.types; {
    enable = lib.mkEnableOption "Enable jakstpub";
    dataDir = lib.mkOption {type = path;};
    # RequiresMountsFor is used by upstream, hacking with the unit
    requires = lib.mkOption {type = listOf str;};
    uidgid = lib.mkOption {type = int;};
    hostname = lib.mkOption {type = str;};
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      virtualHosts.":80".extraConfig = with myData.subnets; ''
        root * ${cfg.dataDir}
        @denied not remote_ip ${vno1.cidr} ${vno3.cidr} ${tailscale.cidr}
        file_server browse {
          hide .stfolder
        }
        encode gzip
      '';
    };

    services.samba = {
      # https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Standalone_Server
      enable = true;
      securityType = "user";
      enableNmbd = false;
      enableWinbindd = false;
      extraConfig = ''
        map to guest = Bad User
        guest account = jakstpub
        server role = standalone server
      '';
      shares = {
        public = {
          path = cfg.dataDir;
          writeable = "yes";
          public = "yes";
          "guest ok" = "yes";
          "read only" = "no";
          "create mask" = "0664";
          "directory mask" = "0775";
          "force user" = "jakstpub";
          "force group" = "jakstpub";
        };
      };
    };

    services.samba-wsdd = {
      enable = true;
      hostname = cfg.hostname;
    };

    users.users.jakstpub = {
      description = "Jakstys Public";
      home = "/var/empty";
      useDefaultShell = true;
      group = "jakstpub";
      isSystemUser = true;
      createHome = false;
      uid = cfg.uidgid;
    };

    users.groups.jakstpub.gid = cfg.uidgid;

    systemd.services.samba-smbd = {
      unitConfig.Requires = cfg.requires;
    };

    mj.services.friendlyport.ports = [
      {
        subnets = with myData.subnets; [tailscale.cidr vno1.cidr vno3.cidr];
        tcp = [
          80 # caddy above
          139 # smbd
          445 # smbd
          5357 # wsdd
        ];
        udp = [3702]; # wsdd
      }
    ];
  };
}

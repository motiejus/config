{
  config,
  lib,
  myData,
  ...
}:
let
  cfg = config.mj.services.jakstpub;
in
{
  options.mj.services.jakstpub = with lib.types; {
    enable = lib.mkEnableOption "Enable jakstpub";
    dataDir = lib.mkOption { type = path; };
    # RequiresMountsFor is used by upstream, hacking with the unit
    requires = lib.mkOption {
      type = listOf str;
      default = [ ];
    };
    uidgid = lib.mkOption { type = int; };
    hostname = lib.mkOption { type = str; };
  };

  config = lib.mkIf cfg.enable {
    services = {
      caddy = {
        enable = true;
        virtualHosts."hdd.jakstys.lt:80".extraConfig = with myData.subnets; ''
          root * ${cfg.dataDir}
          @denied not remote_ip ${vno1.cidr} ${vno3.cidr} ${tailscale.cidr}
          file_server browse {
            hide .stfolder
          }
          encode gzip
        '';
      };

      samba =
        let
          defaults = {
            "public" = "yes";
            "mangled names" = "no";
            "guest ok" = "yes";
            "force user" = "jakstpub";
            "force group" = "jakstpub";
          };
        in
        {
          # https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Standalone_Server
          enable = true;

          nmbd.enable = false;
          winbindd.enable = false;

          settings = {
            global = {
              security = "user";

              "map to guest" = "Bad User";
              "guest account" = "jakstpub";
              "server role" = "standalone server";
            };

            public = defaults // {
              "path" = cfg.dataDir;
              "writeable" = "yes";
              "read only" = "no";
              "create mask" = "0664";
              "directory mask" = "0775";
            };
            #snapshots = defaults // {
            #  "path" = cfg.dataDir + "/.zfs/snapshot";
            #  "writeable" = "no";
            #  "read only" = "yes";
            #};
          };
        };

      samba-wsdd = {
        enable = true;
        inherit (cfg) hostname;
      };
    };

    users.users.jakstpub = {
      description = "Jakstys Public";
      home = "/var/empty";
      shell = "/bin/sh";
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
        subnets = with myData.subnets; [
          tailscale.cidr
          vno1.cidr
          vno3.cidr
        ];
        tcp = [
          #80 # caddy above
          139 # smbd
          445 # smbd
          5357 # wsdd
        ];
        udp = [ 3702 ]; # wsdd
      }
    ];
  };
}

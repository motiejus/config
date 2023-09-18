{
  config,
  lib,
  myData,
  ...
}: let
  guiPort = 8384;
  folders = {
    Books = {
      devices = ["mxp10" "fwminex" "vno1-oh2"];
      id = "8lk0n-mm63y";
      label = "Books";
    };
    M-Active = {
      devices = ["mxp10" "fwminex" "vno1-oh2"];
      id = "f6fma-unkxq";
      label = "M-Active";
    };

  };
in {
  options.mj.services.syncthing = with lib.types; {
    enable = lib.mkEnableOption "Enable services syncthing settings";
    user = lib.mkOption {type = str;};
    group = lib.mkOption {type = str;};
    dataDir = lib.mkOption {type = path;};
  };

  config = lib.mkIf config.mj.services.syncthing.enable {
    mj.services.friendlyport.ports = [
      {
        subnets = myData.subnets.motiejus.cidrs;
        tcp = [8384];
      }
    ];

    services.syncthing = {
      enable = config.mj.services.syncthing.enable;
      openDefaultPorts = true;
      guiAddress = let
        fqdn = with config.networking; "${hostName}.${domain}";
        jakstIP = lib.getAttrFromPath [fqdn "jakstIP"] myData.hosts;
        guiPortStr = builtins.toString guiPort;
      in "${jakstIP}:${guiPortStr}";
      user = config.mj.services.syncthing.user;
      group = config.mj.services.syncthing.group;
      dataDir = config.mj.services.syncthing.dataDir;

      extraOptions.gui.insecureAdminAccess = true;

      devices =
        {}
        // (lib.optionalAttrs (config.networking.hostName == "vno1-oh2") {
          "fwminex".id = "GKSUKZE-AOBQOWY-CNLZ2ZI-WNKATYE-MV4Y452-J3VCJ5C-EAANXRX-2P6EHA6";
          "mxp10".id = "LO54QZZ-5J3G62P-WUVM3MW-7J3VWHD-BG76TOQ-5S7PZSY-JU45K3I-X3ZL4AN";
          "rzj-744P2PE".id = "UW6ISH2-NW6X6AW-BJR76TV-TV3BIGZ-PA5QH2M-YEF567T-IWMHKD5-P3XHHAH";
          "KrekenavosNamai".id = "CYZDYL6-YMW7SZ3-K6IJO4Q-6NOULSG-OVZ3BGN-6LN3CLR-P3BJFKW-2PMHJQT";
        })
        // (lib.optionalAttrs (config.networking.hostName == "fwminex") {
          "fwminex".id = "GKSUKZE-AOBQOWY-CNLZ2ZI-WNKATYE-MV4Y452-J3VCJ5C-EAANXRX-2P6EHA6";
          "vno1-oh2".id = "W45ROUW-CHKI3I6-C4VCOCU-NJYQ3ZS-MJDHH23-YYCDXTI-HTJSBZJ-KZMWTAF";
          "mxp10".id = "LO54QZZ-5J3G62P-WUVM3MW-7J3VWHD-BG76TOQ-5S7PZSY-JU45K3I-X3ZL4AN";
          "rzj-744P2PE".id = "UW6ISH2-NW6X6AW-BJR76TV-TV3BIGZ-PA5QH2M-YEF567T-IWMHKD5-P3XHHAH";
        })
        // {};

      folders =
        {}
        // (
          lib.optionalAttrs (config.networking.hostName == "vno1-oh2") {
            "/var/www/dl/tel" = {
              devices = ["mxp10"];
              id = "gqrtz-prx9h";
              label = "www-tel";
            };
            "/var/www/dl/fwminex" = {
              devices = ["fwminex"];
              id = "7z9sw-2nubh";
              label = "www-fwminex";
            };
            "/var/www/dl/mykolo" = {
              devices = ["mxp10"];
              id = "wslmq-fyw4w";
              label = "mykolo";
            };
            "${config.services.syncthing.dataDir}/annex2/Books" = folders.Books;
            "${config.services.syncthing.dataDir}/annex2/M-Active" = folders.M-Active;
            "${config.services.syncthing.dataDir}/annex2/M-Camera" = {
              devices = ["mxp10" "fwminex"];
              id = "pixel_xl_dtm3-photos";
              label = "M-Active";
            };
            "${config.services.syncthing.dataDir}/annex2/M-Documents" = {
              devices = ["fwminex"];
              id = "4fu7z-z6es2";
              label = "M-Documents";
            };
            "${config.services.syncthing.dataDir}/annex2/R-Documents" = {
              devices = ["rzj-744P2PE"];
              id = "nm23h-aog6k";
              label = "R-Documents";
            };
            "${config.services.syncthing.dataDir}/annex2/Pictures" = {
              devices = ["fwminex"];
              id = "d3hur-cbzyw";
              label = "Pictures";
            };
            "${config.services.syncthing.dataDir}/annex2/M-R" = {
              devices = ["fwminex" "rzj-744P2PE" "mxp10"];
              id = "evgn9-ahngz";
              label = "M-R";
            };
            "${config.services.syncthing.dataDir}/stud-cache" = {
              devices = ["fwminex"];
              id = "2kq7n-jqzxj";
              label = "stud-cache";
            };
            "${config.services.syncthing.dataDir}/video/shared" = {
              devices = ["mxp10" "fwminex"];
              id = "byzmw-f6zhg";
              label = "video-shared";
            };
            "${config.services.syncthing.dataDir}/music" = {
              devices = ["fwminex" "mxp10"];
              id = "tg94v-cqcwr";
              label = "music";
            };
            "${config.services.syncthing.dataDir}/irenos" = {
              devices = ["KrekenavosNamai"];
              id = "wuwai-qkcqj";
              label = "Irenos";
            };
          }
        )
        // (
          lib.optionalAttrs (config.networking.hostName == "fwminex") {
            "/home/motiejus/Books" = folders.Books;
            "/home/motiejus/M-Active" = folders.M-Active;
          }
        );
    };
  };
}

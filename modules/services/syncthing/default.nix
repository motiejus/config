{
  config,
  lib,
  myData,
  ...
}: let
  cfg = config.mj.services.syncthing;

  devices = {
    "fwminex".id = "GKSUKZE-AOBQOWY-CNLZ2ZI-WNKATYE-MV4Y452-J3VCJ5C-EAANXRX-2P6EHA6";
    "mtworx".id = "C72YA2S-PE5IGDZ-DCNFV7Y-I72BGZM-5L2OO7Y-4K5OTGZ-NILAS2V-BGSAUQW";
    "vno1-oh2".id = "W45ROUW-CHKI3I6-C4VCOCU-NJYQ3ZS-MJDHH23-YYCDXTI-HTJSBZJ-KZMWTAF";
    "mxp10".id = "LO54QZZ-5J3G62P-WUVM3MW-7J3VWHD-BG76TOQ-5S7PZSY-JU45K3I-X3ZL4AN";
    "rzj-744P2PE".id = "UW6ISH2-NW6X6AW-BJR76TV-TV3BIGZ-PA5QH2M-YEF567T-IWMHKD5-P3XHHAH";
    "KrekenavosNamai".id = "CYZDYL6-YMW7SZ3-K6IJO4Q-6NOULSG-OVZ3BGN-6LN3CLR-P3BJFKW-2PMHJQT";
    "vno1-vinc".id = "4W3S7R2-OWI6XO6-V4NMDNB-NTIETYP-QJSBQGA-WEIXPHR-WNZZ7R4-VT4COAR";
    "vno2-irena".id = "VL2MA2E-ZDGVHYN-A3Q3EKU-7J625QM-FG7CNXY-UKDL563-MDRRIEG-XQDS3AW";
    "v-kfire".id = "REEDZAL-KPLWARZ-466J4BR-H5UDI6D-UUA33QG-HPZHIMX-WNFLDGD-PJLTFQZ";
    "a-kfire".id = "VIQF4QW-2OLBBIK-XWOIO4A-264J32R-BE4J4BT-WEJXMYO-MXQDQHD-SJ6MEQ7";
  };
  folders = {
    Books = {
      devices = ["fwminex" "vno1-oh2" "mxp10"];
      id = "8lk0n-mm63y";
      label = "Books";
    };
    Mail = {
      devices = ["fwminex" "vno1-oh2"];
      id = "66fmz-x6f1a";
      label = "Mail";
    };
    M-Active = {
      devices = ["mxp10" "fwminex" "mtworx" "vno1-oh2"];
      id = "f6fma-unkxq";
      label = "M-Active";
      versioning = {
        type = "staggered";
        params = {
          cleanInterval = "3600";
          maxAge = builtins.toString (3600 * 24 * 30);
        };
      };
    };
    M-Documents = {
      devices = ["fwminex" "vno1-oh2"];
      id = "4fu7z-z6es2";
      label = "M-Documents";
    };
    Vaikai = {
      devices = ["vno1-vinc" "fwminex" "vno1-oh2" "v-kfire" "rzj-744P2PE" "mxp10" "a-kfire"];
      id = "xbrfr-mhszm";
      label = "Vaikai";
    };
    M-Camera = {
      devices = ["mxp10" "fwminex" "mtworx" "vno1-oh2"];
      id = "pixel_xl_dtm3-photos";
      label = "M-Camera";
    };
    R-Documents = {
      devices = ["rzj-744P2PE" "vno1-oh2"];
      id = "nm23h-aog6k";
      label = "R-Documents";
    };
    Pictures = {
      devices = ["fwminex" "vno1-oh2"];
      id = "d3hur-cbzyw";
      label = "Pictures";
    };
    Music = {
      devices = ["fwminex" "mtworx" "mxp10" "vno1-oh2"];
      id = "tg94v-cqcwr";
      label = "music";
    };
    video-shared = {
      devices = ["mxp10" "mtworx" "fwminex" "vno1-oh2"];
      id = "byzmw-f6zhg";
      label = "video-shared";
    };
    stud-cache = {
      devices = ["fwminex" "vno1-oh2"];
      id = "2kq7n-jqzxj";
      label = "stud-cache";
    };
    M-R = {
      devices = ["fwminex" "rzj-744P2PE" "mxp10" "vno1-oh2"];
      id = "evgn9-ahngz";
      label = "M-R";
    };
    Irenos = {
      devices = ["KrekenavosNamai" "vno1-oh2" "vno2-irena"];
      id = "wuwai-qkcqj";
      label = "Irenos";
    };
    www-fwminex = {
      devices = ["fwminex" "vno1-oh2"];
      id = "7z9sw-2nubh";
      label = "www-fwminex";
    };
    www-mxp10 = {
      devices = ["mxp10" "vno1-oh2"];
      id = "gqrtz-prx9h";
      label = "www-mxp10";
    };
    mykolo = {
      devices = ["mxp10"];
      id = "wslmq-fyw4w";
      label = "mykolo";
    };
  };
in {
  options.mj.services.syncthing = with lib.types; {
    enable = lib.mkEnableOption "Enable services syncthing settings";
    user = lib.mkOption {type = str;};
    group = lib.mkOption {type = str;};
    dataDir = lib.mkOption {type = path;};
  };

  config = lib.mkIf cfg.enable {
    mj.services.friendlyport.ports = [
      {
        subnets = myData.subnets.motiejus.cidrs;
        tcp = [8384];
      }
    ];

    services.syncthing = {
      inherit (cfg) enable user group dataDir;
      openDefaultPorts = true;

      settings = {
        devices =
          {}
          // (lib.optionalAttrs (config.networking.hostName == "vno1-oh2") {
            inherit
              (devices)
              fwminex
              mtworx
              vno1-oh2
              mxp10
              rzj-744P2PE
              KrekenavosNamai
              vno1-vinc
              vno2-irena
              v-kfire
              a-kfire
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "fwminex") {
            inherit
              (devices)
              fwminex
              mtworx
              vno1-oh2
              mxp10
              rzj-744P2PE
              vno1-vinc
              v-kfire
              a-kfire
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "mtworx") {
            inherit
              (devices)
              fwminex
              mtworx
              vno1-oh2
              mxp10
              ;
          })
          // {};
        folders = with folders;
          {}
          // (
            lib.optionalAttrs (config.networking.hostName == "vno1-oh2") {
              "/var/www/dl/tel" = www-mxp10;
              "/var/www/dl/fwminex" = www-fwminex;
              "/var/www/dl/mykolo" = mykolo;
              "${cfg.dataDir}/annex2/Books" = Books;
              "${cfg.dataDir}/annex2/Mail" = Mail;
              "${cfg.dataDir}/annex2/M-Active" = M-Active;
              "${cfg.dataDir}/annex2/M-Camera" = M-Camera;
              "${cfg.dataDir}/annex2/M-Documents" = M-Documents;
              "${cfg.dataDir}/annex2/R-Documents" = R-Documents;
              "${cfg.dataDir}/annex2/Pictures" = Pictures;
              "${cfg.dataDir}/annex2/M-R" = M-R;
              "${cfg.dataDir}/stud-cache" = stud-cache;
              "${cfg.dataDir}/video/shared" = video-shared;
              "${cfg.dataDir}/video/Vaikai" = Vaikai;
              "${cfg.dataDir}/music" = Music;
              "${cfg.dataDir}/irenos" = Irenos;
            }
          )
          // (
            lib.optionalAttrs (config.networking.hostName == "mtworx") {
              "${cfg.dataDir}/M-Active" = M-Active;
              "${cfg.dataDir}/M-Camera" = M-Camera;
              "${cfg.dataDir}/Video" = video-shared;
              "${cfg.dataDir}/music" = Music;
            }
          )
          // (
            lib.optionalAttrs (config.networking.hostName == "fwminex") {
              "${cfg.dataDir}/.cache/evolution" = Mail;
              "${cfg.dataDir}/Books" = Books;
              "${cfg.dataDir}/M-Active" = M-Active;
              "${cfg.dataDir}/M-Documents" = M-Documents;
              "${cfg.dataDir}/M-Camera" = M-Camera;
              "${cfg.dataDir}/Pictures" = Pictures;
              "${cfg.dataDir}/Music" = Music;
              "${cfg.dataDir}/M-R" = M-R;
              "${cfg.dataDir}/Vaikai" = Vaikai;
              "${cfg.dataDir}/Video" = video-shared;
              "${cfg.dataDir}/stud-cache" = stud-cache;
              "${cfg.dataDir}/www" = www-fwminex;
            }
          );
      };
    };
  };
}

{
  config,
  lib,
  ...
}:
let
  cfg = config.mj.services.syncthing;

  devices = {
    "fwminex".id = "GKSUKZE-AOBQOWY-CNLZ2ZI-WNKATYE-MV4Y452-J3VCJ5C-EAANXRX-2P6EHA6";
    "mtworx".id = "C72YA2S-PE5IGDZ-DCNFV7Y-I72BGZM-5L2OO7Y-4K5OTGZ-NILAS2V-BGSAUQW";
    "mxp1".id = "2HBV27D-PK5DKQG-EQE4AV7-ASADXHJ-ER7GAZK-Z6C2NZP-64DLTKI-5OPUZAT";
    "vxp10".id = "CNAGBWH-3EAJ3XR-Z6K2DTW-P42O4SD-7JVCOEL-KIM7BKW-2WA7XS3-733NIQF";
    "rzj-744P2PE".id = "UW6ISH2-NW6X6AW-BJR76TV-TV3BIGZ-PA5QH2M-YEF567T-IWMHKD5-P3XHHAH";
    "sqq1-desk".id = "WJ5KGRS-AGDZ7SW-INIVWHR-Q4E5QX4-Y4TT2AK-QRJTOTL-2UHXX6O-5MUPGA2";
    "vno1-vinc".id = "4W3S7R2-OWI6XO6-V4NMDNB-NTIETYP-QJSBQGA-WEIXPHR-WNZZ7R4-VT4COAR";
    "vno1-gdrx".id = "XOZO6GL-MEH55QR-PTNRVHE-45PD3L2-SHP7XW6-VXKROQ5-F47U3AX-QQACLQP";
    "vno2-irena".id = "VL2MA2E-ZDGVHYN-A3Q3EKU-7J625QM-FG7CNXY-UKDL563-MDRRIEG-XQDS3AW";
    "vno2-desk2".id = "HUM7DHH-54XEV44-UVIK3TJ-DDMUFKR-S6IHDMB-6XXOSP2-3RKL4TB-M5VCGAQ";
    "vno3-nk".id = "HDESTGW-C3PGZLU-7V7KLWP-SIJVM3V-JEG6OMT-CGOLOQW-DZMIPS7-G7SVSQB";
    "v-kfire".id = "REEDZAL-KPLWARZ-466J4BR-H5UDI6D-UUA33QG-HPZHIMX-WNFLDGD-PJLTFQZ";
    "a-kfire".id = "VIQF4QW-2OLBBIK-XWOIO4A-264J32R-BE4J4BT-WEJXMYO-MXQDQHD-SJ6MEQ7";
  };
  folders = {
    Zemelapiai = {
      devices = [
        "vno1-gdrx"
        "vno3-nk"
        "mtworx"
      ];
      id = "ahz8ohSh";
      label = "Zemelapiai";
    };
    Books = {
      devices = [
        "vno1-gdrx"
        "fwminex"
        "mxp1"
      ];
      id = "8lk0n-mm63y";
      label = "Books";
    };
    Maildir = {
      devices = [
        "vno1-gdrx"
        "fwminex"
      ];
      id = "9lk1k-za124";
      label = "Maildir";
    };
    M-Active = {
      devices = [
        "vno1-gdrx"
        "mxp1"
        "fwminex"
        "mtworx"
      ];
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
      devices = [
        "vno1-gdrx"
        "fwminex"
      ];
      id = "4fu7z-z6es2";
      label = "M-Documents";
    };
    Vaikai = {
      devices = [
        "vno1-vinc"
        "vno2-desk2"
        "vno1-gdrx"
        "fwminex"
        "mtworx"
        "v-kfire"
        "a-kfire"
        "vxp10"
      ];
      id = "xbrfr-mhszm";
      label = "Vaikai";
    };
    M-Camera = {
      devices = [
        "mxp1"
        "vno1-gdrx"
        "fwminex"
        "mtworx"
      ];
      id = "pixel_xl_dtm3-photos";
      label = "M-Camera";
    };
    R-Documents = {
      devices = [ "rzj-744P2PE" ];
      id = "nm23h-aog6k";
      label = "R-Documents";
    };
    Pictures = {
      devices = [
        "vno1-gdrx"
        "fwminex"
      ];
      id = "d3hur-cbzyw";
      label = "Pictures";
    };
    Music = {
      devices = [
        "vno1-gdrx"
        "fwminex"
        "mtworx"
        "mxp1"
      ];
      id = "tg94v-cqcwr";
      label = "music";
    };
    video-shared = {
      devices = [
        "vno1-gdrx"
        "mxp1"
        "mtworx"
        "fwminex"
      ];
      id = "byzmw-f6zhg";
      label = "video-shared";
    };
    stud-cache = {
      devices = [
        "vno1-gdrx"
        "fwminex"
        "mtworx"
      ];
      id = "2kq7n-jqzxj";
      label = "stud-cache";
    };
    M-R = {
      devices = [
        "vno1-gdrx"
        "fwminex"
        "rzj-744P2PE"
        "mxp1"
        "mxp1"
        "mtworx"
      ];
      id = "evgn9-ahngz";
      label = "M-R";
    };
    Irenos = {
      devices = [
        "fwminex"
        "vno1-gdrx"
        "vno2-irena"
        "vno2-desk2"
      ];
      id = "wuwai-qkcqj";
      label = "Irenos";
    };
    www-vno1-gdrx = {
      devices = [
        "fwminex"
        "vno1-gdrx"
      ];
      id = "7z7ao-3hbxi";
      label = "www-vno1-gdrx";
    };
    www-mtworx = {
      devices = [
        "mtworx"
        "fwminex"
      ];
      id = "7z9sw-aaaa";
      label = "www-mtworx";
    };
    www-mxp1 = {
      devices = [ "mxp1" ];
      id = "gqrtz-prx9h";
      label = "www-mxp1";
    };
  };
in
{
  options.mj.services.syncthing = with lib.types; {
    enable = lib.mkEnableOption "Enable services syncthing settings";
    user = lib.mkOption { type = str; };
    group = lib.mkOption { type = str; };
    dataDir = lib.mkOption { type = path; };
  };

  config = lib.mkIf cfg.enable {
    services.syncthing = {
      inherit (cfg)
        enable
        user
        group
        dataDir
        ;
      openDefaultPorts = true;
      key = config.age.secrets.syncthing-key.path;
      cert = config.age.secrets.syncthing-cert.path;

      settings = {
        devices =
          { }
          // (lib.optionalAttrs (config.networking.hostName == "vno1-gdrx") {
            inherit (devices)
              vno1-gdrx
              vno3-nk
              fwminex
              mtworx
              mxp1
              vxp10
              vno2-irena
              vno2-desk2
              rzj-744P2PE
              vno1-vinc
              v-kfire
              a-kfire
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "vno2-desk2") {
            inherit (devices)
              vno2-desk2
              vxp10
              mtworx
              fwminex
              v-kfire
              a-kfire
              sqq1-desk
              vno1-vinc
              vno1-gdrx
              vno2-irena
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "vno3-nk") {
            inherit (devices)
              vno3-nk
              vno1-gdrx
              fwminex
              mtworx
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "fwminex") {
            inherit (devices)
              vno1-gdrx
              vno3-nk
              fwminex
              mtworx
              mxp1
              vxp10
              rzj-744P2PE
              vno1-vinc
              vno2-irena
              vno2-desk2
              v-kfire
              a-kfire
              ;
          })
          // (lib.optionalAttrs (config.networking.hostName == "mtworx") {
            inherit (devices)
              mtworx
              vno2-desk2
              vno1-gdrx
              vno3-nk
              fwminex
              vno1-vinc
              rzj-744P2PE
              mxp1
              vxp10
              a-kfire
              v-kfire
              ;
          })
          // { };
        folders =
          with folders;
          { }
          // (lib.optionalAttrs (config.networking.hostName == "fwminex") {
            "/var/www/dl/tel" = www-mxp1;
            "/var/www/dl/vno1-gdrx" = www-vno1-gdrx;
            "/var/www/dl/mtworx" = www-mtworx;
            "${cfg.dataDir}/annex2/Books" = Books;
            "${cfg.dataDir}/annex2/Maildir" = Maildir;
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
          })
          // (lib.optionalAttrs (config.networking.hostName == "vno3-nk") {
            "/data/vno3-shared/Zemelapiai" = Zemelapiai;
          })
          // (lib.optionalAttrs (config.networking.hostName == "mtworx") {
            "${cfg.dataDir}/M-Active" = M-Active;
            "${cfg.dataDir}/M-Camera" = M-Camera;
            "${cfg.dataDir}/M-R" = M-R;
            "${cfg.dataDir}/Zemelapiai" = Zemelapiai;
            "${cfg.dataDir}/Vaikai" = Vaikai;
            "${cfg.dataDir}/Video" = video-shared;
            "${cfg.dataDir}/music" = Music;
            "${cfg.dataDir}/www" = www-mtworx;
            "${cfg.dataDir}/stud-cache" = stud-cache;
          })
          // (lib.optionalAttrs (config.networking.hostName == "vno1-gdrx") {
            "${cfg.dataDir}/Books" = Books;
            "${cfg.dataDir}/Maildir" = Maildir;
            "${cfg.dataDir}/irenos" = Irenos;
            "${cfg.dataDir}/M-Active" = M-Active;
            "${cfg.dataDir}/M-Camera" = M-Camera;
            "${cfg.dataDir}/M-Documents" = M-Documents;
            "${cfg.dataDir}/Pictures" = Pictures;
            "${cfg.dataDir}/Zemelapiai" = Zemelapiai;
            "${cfg.dataDir}/M-R" = M-R;
            "${cfg.dataDir}/stud-cache" = stud-cache;
            "${cfg.dataDir}/video/shared" = video-shared;
            "${cfg.dataDir}/video/Vaikai" = Vaikai;
            "${cfg.dataDir}/music" = Music;
            "${cfg.dataDir}/www" = www-vno1-gdrx;
          })
          // (lib.optionalAttrs (config.networking.hostName == "vno2-desk2") {
            "${cfg.dataDir}/Sync" = Irenos;
            "${cfg.dataDir}/Vaikai" = Vaikai;
          });
      };
    };
  };
}

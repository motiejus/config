{
  config,
  lib,
  myData,
  ...
}: let
  guiPort = 8384;
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
        subnets = myData.motiejus_ips;
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
          "fwmine".id = "GKSUKZE-AOBQOWY-CNLZ2ZI-WNKATYE-MV4Y452-J3VCJ5C-EAANXRX-2P6EHA6";
          "mxp10".id = "LO54QZZ-5J3G62P-WUVM3MW-7J3VWHD-BG76TOQ-5S7PZSY-JU45K3I-X3ZL4AN";
          "rzj-744P2PE".id = "UW6ISH2-NW6X6AW-BJR76TV-TV3BIGZ-PA5QH2M-YEF567T-IWMHKD5-P3XHHAH";
          "KrekenavosNamai".id = "CYZDYL6-YMW7SZ3-K6IJO4Q-6NOULSG-OVZ3BGN-6LN3CLR-P3BJFKW-2PMHJQT";
        })
        // {};

      folders = {
        "/var/www/dl/tel" = {
          devices = ["mxp10"];
          id = "gqrtz-prx9h";
          label = "www-tel";
        };
        "/var/www/dl/fwmine" = {
          devices = ["fwmine"];
          id = "7z9sw-2nubh";
          label = "www-fwmine";
        };
        "/var/www/dl/mykolo" = {
          devices = ["mxp10"];
          id = "wslmq-fyw4w";
          label = "mykolo";
        };
        "${config.services.syncthing.dataDir}/annex2/Books" = {
          devices = ["mxp10" "fwmine"];
          id = "8lk0n-mm63y";
          label = "Books";
        };
        "${config.services.syncthing.dataDir}/annex2/M-Active" = {
          devices = ["mxp10" "fwmine"];
          id = "f6fma-unkxq";
          label = "M-Active";
        };
        "${config.services.syncthing.dataDir}/annex2/M-Camera" = {
          devices = ["mxp10" "fwmine"];
          id = "pixel_xl_dtm3-photos";
          label = "M-Active";
        };
        "${config.services.syncthing.dataDir}/annex2/M-Documents" = {
          devices = ["fwmine"];
          id = "4fu7z-z6es2";
          label = "M-Documents";
        };
        "${config.services.syncthing.dataDir}/annex2/R-Documents" = {
          devices = ["rzj-744P2PE"];
          id = "nm23h-aog6k";
          label = "R-Documents";
        };
        "${config.services.syncthing.dataDir}/annex2/Pictures" = {
          devices = ["fwmine"];
          id = "d3hur-cbzyw";
          label = "Pictures";
        };
        "${config.services.syncthing.dataDir}/annex2/M-R" = {
          devices = ["fwmine" "rzj-744P2PE" "mxp10"];
          id = "evgn9-ahngz";
          label = "M-R";
        };
        "${config.services.syncthing.dataDir}/stud-cache" = {
          devices = ["fwmine"];
          id = "2kq7n-jqzxj";
          label = "stud-cache";
        };
        "${config.services.syncthing.dataDir}/video/shared" = {
          devices = ["mxp10" "fwmine"];
          id = "byzmw-f6zhg";
          label = "video-shared";
        };
        "${config.services.syncthing.dataDir}/music" = {
          devices = ["fwmine" "mxp10"];
          id = "tg94v-cqcwr";
          label = "music";
        };
        "${config.services.syncthing.dataDir}/irenos" = {
          devices = ["KrekenavosNamai"];
          id = "wuwai-qkcqj";
          label = "Irenos";
        };
      };
    };
  };
}

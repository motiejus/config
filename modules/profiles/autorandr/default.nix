{ config, ... }:
let
  eDP-1 = {
    vno1-gdrx = {
      fingerprint = "00ffffffffffff0006afb01d0000000032210104a51e13780370f59c4c45921e07505400000001010101010101010101010101010101263d80b870b02840101035002dbc10000018c42880b870b02840101035002dbc1000001800000003000266ff04647d0c09137d00000000000003000d38ff2296900d0b499001012001ac70207902002200147b6302857f07b7000f800f00af042700020004002501097b63027b6302283c8081001c741a00000301283c0000801280123c000000000000e6060101808044000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001790";
      mode = "0x0";
    };
  };

  home-DP-4-1-1-vertical = {
    fingerprint = "00ffffffffffff0010ac33424c38334114200104b53c22783eee95a3544c99260f5054a54b00714f8180a9c0a940d1c0010101010101565e00a0a0a029503020350055502100001a000000ff004a4450444448330a2020202020000000fc0044454c4c20553237323244450a000000fd00314c1e5a19010a2020202020200144020319f14c90040302011112131f20212223097f0783010000023a801871382d40582c450055502100001e7e3900a080381f4030203a0055502100001a011d007251d01e206e28550055502100001ebf1600a08038134030203a0055502100001a00000000000000000000000000000000000000000000000000000000000006";
    mode = "2560x1440";
  };

  home-DP-4-8-horizontal = {
    fingerprint = "00ffffffffffff0010ac5d424c32313804200104b54028783a94f5af4f47a4240e5054a54b00d100d1c0b300a94081808100714f0101e26800a0a0402e603020360081912100001a000000ff003934585a3548330a2020202020000000fc0044454c4c205533303233450a20000000fd00384c1e711c010a20202020202001ee020319f14c90040302011112131f20212223097f0783010000023a801871382d40582c450081912100001e7e3900a080381f4030203a0081912100001a011d007251d01e206e28550081912100001ebf1600a08038134030203a0081912100001a00000000000000000000000000000000000000000000000000000000000052";
    mode = "2560x1600";
  };
in
{
  services.autorandr = {
    enable = true;
    matchEdid = true;

    profiles = rec {
      default = {
        fingerprint = {
          eDP-1 = eDP-1.${config.networking.hostName}.fingerprint;
        };
        config = {
          eDP-1 = {
            inherit (eDP-1.${config.networking.hostName}) mode;
            enable = true;
            primary = true;
            crtc = 0;
            position = "0x0";
          };
        };
      };

      home-lidclosed = {
        fingerprint = {
          home-DP-4-1-1-vertical = home-DP-4-1-1-vertical.fingerprint;
          home-DP-4-8-horizontal = home-DP-4-8-horizontal.fingerprint;
        };
        config = {
          home-DP-4-8-horizontal = {
            inherit (home-DP-4-8-horizontal) mode;
            enable = true;
            crtc = 0;
            position = "1440x413";
          };
          home-DP-4-1-1-vertical = {
            inherit (home-DP-4-1-1-vertical) mode;
            enable = true;
            crtc = 1;
            rotate = "right";
          };
        };
      };

      home-lidopen = {
        fingerprint = {
          home-DP-4-1-1-vertical = home-DP-4-1-1-vertical.fingerprint;
          home-DP-4-8-horizontal = home-DP-4-8-horizontal.fingerprint;
          eDP-1 = eDP-1.${config.networking.hostName}.fingerprint;
        };
        inherit (home-lidclosed) config;
      };
    };
  };
}

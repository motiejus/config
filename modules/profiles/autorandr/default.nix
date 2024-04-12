{config, ...}: let
  eDP-1 = {
    mtworx = {
      fingerprint = "00ffffffffffff000e6f041400000000001e0104a51e1378033784a5544d9a240e515500000001010101010101010101010101010101353c80a070b02340302036002ebd10000018000000fd00303c4a4a0f010a202020202020000000fe0043534f542054330a2020202020000000fe004d4e453030374a41312d310a2000b5";
      mode = "1920x1200";
    };
    fwminex = {
      fingerprint = "00ffffffffffff0009e55f0900000000171d0104a51c137803de50a3544c99260f505400000001010101010101010101010101010101115cd01881e02d50302036001dbe1000001aa749d01881e02d50302036001dbe1000001a000000fe00424f452043510a202020202020000000fe004e4531333546424d2d4e34310a00fb";
      mode = "1920x1200";
    };
  };

  work-DP-3 = {
    fingerprint = "00ffffffffffff001e6d07778068040002200104b53c22789e3e31ae5047ac270c50542108007140818081c0a9c0d1c08100010101014dd000a0f0703e803020650c58542100001a286800a0f0703e800890650c58542100001a000000fd00383d1e8738000a202020202020000000fc004c472048445220344b0a202020017e0203197144900403012309070783010000e305c000e3060501023a801871382d40582c450058542100001e565e00a0a0a029503020350058542100001a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000029";
    mode = "3840x2160";
  };

  home-DP-4-1-1-vertical = {
    fingerprint = "00ffffffffffff0010ac33424c38334114200104b53c22783eee95a3544c99260f5054a54b00714f8180a9c0a940d1c0010101010101565e00a0a0a029503020350055502100001a000000ff004a4450444448330a2020202020000000fc0044454c4c20553237323244450a000000fd00314c1e5a19010a2020202020200144020319f14c90040302011112131f20212223097f0783010000023a801871382d40582c450055502100001e7e3900a080381f4030203a0055502100001a011d007251d01e206e28550055502100001ebf1600a08038134030203a0055502100001a00000000000000000000000000000000000000000000000000000000000006";
    mode = "2560x1440";
  };

  home-DP-4-8-horizontal = {
    fingerprint = "00ffffffffffff0010ac5d424c32313804200104b54028783a94f5af4f47a4240e5054a54b00d100d1c0b300a94081808100714f0101e26800a0a0402e603020360081912100001a000000ff003934585a3548330a2020202020000000fc0044454c4c205533303233450a20000000fd00384c1e711c010a20202020202001ee020319f14c90040302011112131f20212223097f0783010000023a801871382d40582c450081912100001e7e3900a080381f4030203a0081912100001a011d007251d01e206e28550081912100001ebf1600a08038134030203a0081912100001a00000000000000000000000000000000000000000000000000000000000052";
    mode = "2560x1600";
  };
in {
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
            enable = true;
            primary = true;
            crtc = 0;
            position = "0x0";
            mode = eDP-1.${config.networking.hostName}.mode;
          };
        };
      };

      work-lidclosed = {
        fingerprint = {
          work-DP-3 = work-DP-3.fingerprint;
        };
        config = {
          work-DP-3 = {
            inherit (work-DP-3) mode;
            enable = true;
            primary = true;
            crtc = 0;
            position = "1920x0";
          };
        };
      };

      work-lidopen = {
        fingerprint = {
          eDP-1 = eDP-1.${config.networking.hostName}.fingerprint;
          work-DP-3 = work-DP-3.fingerprint;
        };
        config = {
          work-DP-3 = {
            inherit (work-DP-3) mode;
            enable = true;
            primary = true;
            crtc = 0;
            position = "1920x0";
          };
          eDP-1 = {
            enable = true;
            crtc = 1;
            position = "0x960";
            mode = eDP-1.${config.networking.hostName}.mode;
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

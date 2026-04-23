{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.mj;
in
{
  imports = [ ../base ];

  config = {
    nix.gc.interval = {
      Weekday = 0;
      Hour = 2;
      Minute = 0;
    };

    users.users.${cfg.username}.home = "/Users/${cfg.username}";

    system = {
      primaryUser = cfg.username;
      keyboard = {
        enableKeyMapping = true;
        nonUS.remapTilde = true;
      };

      defaults = {
        dock = {
          autohide-time-modifier = 0.0;
          autohide-delay = 0.0;
          expose-animation-duration = 0.0;
          launchanim = false;
          mineffect = "scale";
        };

        NSGlobalDomain = {
          NSAutomaticWindowAnimationsEnabled = false;
          NSScrollAnimationEnabled = false;
          NSWindowResizeTime = 0.001;
          "com.apple.swipescrolldirection" = false;
          NSWindowShouldDragOnGesture = true;
        };

        screensaver.askForPassword = true;
        screensaver.askForPasswordDelay = 0;

        menuExtraClock.ShowSeconds = true;
        # Show24Hour, ShowDate, DateFormat are ignored by macOS Tahoe;
        # set manually in System Settings > Control Center > Clock Options.

        CustomUserPreferences."com.apple.symbolichotkeys" =
          let
            selectPreviousInputSource = "60";
            shift = 131072;
            option = 524288; # Alt
            spaceAscii = 32;
            spaceVirtualKey = 49;
          in
          {
            AppleSymbolicHotKeys = {
              ${selectPreviousInputSource} = {
                enabled = true;
                value = {
                  parameters = [
                    spaceAscii
                    spaceVirtualKey
                    (shift + option)
                  ];
                  type = "standard";
                };
              };
            };
          };

        CustomUserPreferences."com.apple.HIToolbox" = {
          AppleEnabledInputSources = [
            {
              InputSourceKind = "Keyboard Layout";
              "KeyboardLayout ID" = 0;
              "KeyboardLayout Name" = "U.S.";
            }
            {
              InputSourceKind = "Keyboard Layout";
              "KeyboardLayout ID" = 30;
              "KeyboardLayout Name" = "Lithuanian";
            }
          ];
        };
      };
    };

    programs = {
      bash = {
        enable = true;
        interactiveShellInit = ''
          # Provide a nice prompt if the terminal supports it.
          if [ "$TERM" != "dumb" ] || [ -n "$INSIDE_EMACS" ]; then
            PROMPT_COLOR="1;31m"
            ((UID)) && PROMPT_COLOR="1;32m"
            if [ -n "$INSIDE_EMACS" ]; then
              PS1="\n\[\033[$PROMPT_COLOR\][\u@\h:\w]\\$\[\033[0m\] "
            else
              PS1="\n\[\033[$PROMPT_COLOR\][\u@\h:\w]\\$\[\033[0m\] "
              if [[ "$TERM" =~ xterm ]]; then
                PS1="\[\033]0;\u@\h: \w\007\]$PS1"
              fi
            fi
          fi
        '';
      };

      zsh.enable = lib.mkForce false;
    };
    environment = {
      shells = [ pkgs.bash ];

      systemPackages = with pkgs; [
        watch
      ];
    };

    system.activationScripts.postActivation.text = ''
      dscl . -create /Users/${cfg.username} UserShell /run/current-system/sw/bin/bash
    '';

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bk";
      users.${cfg.username} = {
        imports = [ ../../shared/home ];
        home = {
          inherit (cfg) stateVersion username;
          homeDirectory = "/Users/${cfg.username}";
        };
        targets.darwin.copyApps.enable = false;
        targets.darwin.linkApps.enable = true;
        programs.ssh = {
          enable = true;
          enableDefaultConfig = false;
          matchBlocks."*" = {
            identityFile = [ "~/.ssh/id_ed25519" ];
            extraOptions = {
              AddKeysToAgent = "yes";
              UseKeychain = "yes";
            };
          };
        };
      };
    };
  };
}

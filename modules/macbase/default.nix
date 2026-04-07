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
  options.mj.base.mac = with lib.types; {
    devTools = lib.mkOption {
      type = bool;
      default = false;
    };
    email = lib.mkOption {
      type = nullOr str;
      default = null;
    };
  };

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

        menuExtraClock.ShowSeconds = true;
        # Show24Hour, ShowDate, DateFormat are ignored by macOS Tahoe;
        # set manually in System Settings > Control Center > Clock Options.

        CustomUserPreferences."com.apple.symbolichotkeys" = let
          selectPreviousInputSource = "60";
          shift = 131072;
          option = 524288; # Alt
          spaceAscii = 32;
          spaceVirtualKey = 49;
        in {
          AppleSymbolicHotKeys = {
            ${selectPreviousInputSource} = {
              enabled = true;
              value = {
                parameters = [ spaceAscii spaceVirtualKey (shift + option) ];
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

    services.aerospace = {
      enable = true;
      settings = {
        mode.main.binding = {
          # Focus (awesome: mod+j/k), wraps around within workspace + across monitors
          alt-j = "focus --boundaries-action wrap-around-the-workspace dfs-next";
          alt-k = "focus --boundaries-action wrap-around-the-workspace dfs-prev";
          alt-h = "focus --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors left";
          alt-l = "focus --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors right";

          # Swap windows (awesome: mod+shift+j/k)
          alt-shift-j = "move down";
          alt-shift-k = "move up";
          alt-shift-h = "move left";
          alt-shift-l = "move right";

          # Focus monitor (awesome: mod+ctrl+j/k)
          alt-ctrl-j = "focus-monitor --wrap-around next";
          alt-ctrl-k = "focus-monitor --wrap-around prev";

          # Move window to monitor (awesome: mod+o)
          alt-o = "move-node-to-monitor --wrap-around --focus-follows-window next";

          # Fullscreen (awesome: mod+f)
          #alt-f = "fullscreen";

          # Close window (awesome: mod+shift+c / mod+shift+q)
          alt-shift-c = "close";
          alt-shift-q = "close";

          # Toggle floating (awesome: mod+ctrl+space)
          alt-ctrl-space = "layout floating tiling";

          # Toggle layout (awesome: mod+space)
          alt-space = "layout tiles horizontal vertical";

          # Resize
          alt-minus = "resize smart -50";
          alt-equal = "resize smart +50";
          alt-r = "mode resize";

          # Workspaces (awesome: mod+1-9)
          alt-1 = "workspace 1";
          alt-2 = "workspace 2";
          alt-3 = "workspace 3";
          alt-4 = "workspace 4";
          alt-5 = "workspace 5";
          alt-6 = "workspace 6";
          alt-7 = "workspace 7";
          alt-8 = "workspace 8";
          alt-9 = "workspace 9";

          # Move window to workspace (awesome: mod+shift+1-9)
          alt-shift-1 = "move-node-to-workspace 1";
          alt-shift-2 = "move-node-to-workspace 2";
          alt-shift-3 = "move-node-to-workspace 3";
          alt-shift-4 = "move-node-to-workspace 4";
          alt-shift-5 = "move-node-to-workspace 5";
          alt-shift-6 = "move-node-to-workspace 6";
          alt-shift-7 = "move-node-to-workspace 7";
          alt-shift-8 = "move-node-to-workspace 8";
          alt-shift-9 = "move-node-to-workspace 9";

          # Cycle workspaces
          ctrl-alt-left = "workspace --wrap-around prev";
          ctrl-alt-right = "workspace --wrap-around next";

          # Lock screen (awesome: mod+x)
          alt-x = "exec-and-forget pmset displaysleepnow";

          # Terminal (awesome: mod+return)
          alt-enter = "exec-and-forget open -na Ghostty";
        };

        mode.resize.binding = {
          h = "resize width -50";
          l = "resize width +50";
          j = "resize height +50";
          k = "resize height -50";
          esc = "mode main";
          enter = "mode main";
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
    environment.shells = [ pkgs.bash ];

    system.activationScripts.postActivation.text = ''
      dscl . -create /Users/${cfg.username} UserShell /run/current-system/sw/bin/bash
    '';

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bk";
      users.${cfg.username} =
        { pkgs, ... }:
        import ../../shared/home {
          inherit lib pkgs;
          inherit (cfg) stateVersion username;
          inherit (cfg.base.mac) devTools email;
          homeDirectory = "/Users/${cfg.username}";
        };
    };
  };
}

{ lib, pkgs, ... }:
let
  clipboard = if pkgs.stdenv.isDarwin then "pbcopy" else "xclip -selection clipboard";
in
{
  home.file = {
    ".parallel/will-cite".text = "";
  };

  programs = {
    direnv.enable = true;
    man = {
      enable = true;
      generateCaches = true;
    };

    neovim = {
      enable = true;
      vimAlias = true;
      vimdiffAlias = true;
      defaultEditor = true;
      plugins = [ pkgs.vimPlugins.fugitive ];
      extraConfig = builtins.readFile ./vimrc;
    };

    git = {
      enable = true;
      settings = {
        user.name = "Motiejus Jakštys";
        user.email = lib.mkDefault "motiejus@jakstys.lt";
        alias = {
          yolo = "commit --amend --no-edit -a";
          pushf = "push --force-with-lease";
        };
        log.date = "iso-strict-local";
        pull.ff = "only";
        core.abbrev = 12;
        pretty.fixes = "Fixes: %h (\"%s\")";
        rerere.enabled = true;
        init.defaultBranch = "main";
        merge.conflictstyle = "zdiff3";
        push.autoSetupRemote = true;
        sendemail = {
          sendmailcmd = lib.getExe pkgs.msmtp;
          smtpserveroption = [
            "-a"
            "mj"
          ];
          confirm = "always";
          suppresscc = "self";
        };
      };
    };

    gpg = {
      enable = true;
      mutableKeys = false;
      mutableTrust = false;
      publicKeys = [
        {
          source = ./motiejus-gpg.txt;
          trust = "ultimate";
        }
      ];
    };

    htop = {
      enable = true;
      settings = {
        header_layout = "two_33_67";
        column_meters_0 = "Memory Swap NetworkIO DiskIO LoadAverage Uptime";
        column_meter_modes_0 = "1 1 2 2 2 2";
        column_meters_1 = "AllCPUs2";
        column_meter_modes_1 = "1";
        hide_kernel_threads = "1";
        hide_userland_threads = "1";
        show_cpu_frequency = "1";
        show_cpu_temperature = "0";
      };
    };

    tmux = {
      enable = true;
      keyMode = "vi";
      historyLimit = 1000000;
      extraConfig = ''
        bind  k  clear-history
        bind  c  new-window      -c "#{pane_current_path}"
        bind  %  split-window -h -c "#{pane_current_path}"
        bind '"' split-window -v -c "#{pane_current_path}"

        # neovim :checkhealth
        set-option -sg escape-time 10
        set-option -g default-terminal "screen-256color"
        set-option -sa terminal-features ',xterm-256color:RGB'
      '';
    };

    bash = {
      enable = true;
      shellAliases = {
        "gp" = "${pkgs.git}/bin/git remote | ${pkgs.parallel}/bin/parallel --verbose git push";
      }
      // {
        "l" = "echo -n ł | ${clipboard}";
        "L" = "echo -n Ł | ${clipboard}";
      };
      initExtra = ''
        t() { git rev-parse --show-toplevel; }
        d() { date --utc --date=@$(echo "$1" | sed -E 's/^[^1-9]*([0-9]{10}).*/\1/') +"%F %T"; }
        source ${./gg.sh}
      '';
    };
  };
}

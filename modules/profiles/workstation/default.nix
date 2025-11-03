{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (config.mj) username;
in
{
  imports = [ ../desktop ];

  config = {
    services.xserver = {
      windowManager.awesome.enable = true;
    };

    services.displayManager = {
      defaultSession = lib.mkDefault "none+awesome";
    };

    environment.systemPackages =
      with pkgs;
      [
        rr
        wrk2
        cloc
        josm
        pdal
        gdal
        flex
        ninja
        putty
        bison
        shfmt
        tokei
        shfmt
        bloaty
        skopeo
        inferno
        neomutt
        undocker
        chromium
        binutils
        patchelf
        valgrind
        musl.dev
        graphviz
        qgis-ltr
        cppcheck
        wasmtime
        bpftrace
        hyperfine
        sloccount
        tesseract
        postgresql
        gcc_latest
        borgbackup
        #diffoscope # broken on 2025-09-28, not used much
        git-filter-repo
        nixpkgs-review
        wineWowPackages.full
        openorienteering-mapper

        (texlive.combine {
          inherit (texlive)
            lithuanian
            scheme-medium
            hyphen-lithuanian
            collection-binextra
            collection-bibtexextra
            collection-latexextra
            collection-publishers
            ;
        })
      ]
      ++ (with llvmPackages_19; [
        clang
        lld.dev
        llvm.dev
        clang-tools
        libllvm.dev
        libclang.dev
        llvm-manpages
        clang-manpages
        compiler-rt.dev
      ]);

    home-manager.users.${username} =
      { pkgs, ... }:
      {
        xdg.configFile = {
          "awesome/rc.lua".source = ../desktop/rc.lua;
          "gdb/gdbinit".text = ''
            set style address foreground yellow
            set style function foreground cyan
            set style string foreground magenta
          '';
        };

        programs = {
          msmtp.enable = true;
          mbsync.enable = true;
          neomutt.enable = true;
          notmuch.enable = true;

          tmux.extraConfig =
            let
              cmd = "${pkgs.extract_url}/bin/extract_url";
              cfg = pkgs.writeText "urlviewrc" "COMMAND systemd-run --user --collect xdg-open %s";
            in
            ''
              bind-key u capture-pane -J \; \
                save-buffer /tmp/tmux-buffer \; \
                delete-buffer \; \
                split-window -l 10 "${cmd} -c ${cfg} /tmp/tmux-buffer"
            '';
        };

        accounts.email = {
          maildirBasePath = "Maildir";

          accounts.mj = {
            primary = true;
            userName = "motiejus@jakstys.lt";
            address = "motiejus@jakstys.lt";
            realName = "Motiejus Jakštys";
            passwordCommand = "cat /home/${username}/.mail-appcode";
            imap.host = "imap.gmail.com";
            smtp.host = "smtp.gmail.com";

            mbsync = {
              enable = true;
              create = "maildir";
              patterns = [
                "*"
                "![Gmail]/All Mail"
              ];
            };

            msmtp = {
              enable = true;
            };

            notmuch = {
              enable = true;
              neomutt.enable = true;
            };

            neomutt = {
              enable = true;
              extraConfig = ''
                set index_format="%4C %Z %{%F %H:%M} %-15.15L (%?l?%4l&%4c?) %s"

                set mailcap_path = ${pkgs.writeText "mailcaprc" ''
                  text/html; ${pkgs.elinks}/bin/elinks -dump ; copiousoutput;
                  application/*; ${pkgs.xdg-utils}/bin/xdg-open %s &> /dev/null &;
                  image/*; ${pkgs.xdg-utils}/bin/xdg-open %s &> /dev/null &;
                ''}
                auto_view text/html
                unset record
                set send_charset="utf-8"

                macro attach 'V' "<pipe-entry>iconv -c --to-code=UTF8 > ~/.cache/mutt/mail.html<enter><shell-escape>firefox ~/.cache/mutt/mail.html<enter>"
                macro index,pager \cb "<pipe-message> env BROWSER=firefox urlscan<Enter>" "call urlscan to extract URLs out of a message"
                macro attach,compose \cb "<pipe-entry> env BROWSER=firefox urlscan<Enter>" "call urlscan to extract URLs out of a message"

                set sort_browser=date
                set sort=reverse-threads
                set sort_aux=last-date-received

                bind pager g top
                bind pager G bottom
                bind attach,index g first-entry
                bind attach,index G last-entry
                bind attach,index,pager \CD half-down
                bind attach,index,pager \CU half-up
                bind attach,index,pager \Ce next-line
                bind attach,index,pager \Cy previous-line
                bind index,pager B sidebar-toggle-visible
                bind index,pager R group-reply

                set sidebar_visible = yes
                set sidebar_width = 15
                bind index,pager \Cp sidebar-prev
                bind index,pager \Cn sidebar-next
                bind index,pager \Co sidebar-open
                bind index,pager B sidebar-toggle-visible
                set sidebar_short_path = yes
                set sidebar_delim_chars = '/'
                set sidebar_format = '%B%* %?N?%N?'
                set mail_check_stats
                set postponed="+[Gmail]/Drafts"
                mailboxes =btrfs
                mailboxes =Debian
                mailboxes =alerts
                mailboxes ="[Gmail]/Drafts"
                mailboxes ="[Gmail]/Starred"
                mailboxes ="[Gmail]/Sent Mail"

                source ${../desktop/notmuch-colors.muttrc}
              '';
            };
          };
        };
      };
  };
}

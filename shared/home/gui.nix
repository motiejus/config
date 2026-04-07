{ lib, pkgs, ... }:
{
  programs = {
    chromium = lib.mkIf pkgs.stdenv.isLinux {
      enable = true;
      extensions = [
        { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; } # ublock origin
        { id = "mdjildafknihdffpkfmmpnpoiajfjnjd"; } # consent-o-matic
      ];
    };

    firefox = {
      enable = true;
      # TODO(26.05): switch back to pkgs.firefox-bin
      package = if pkgs.stdenv.isDarwin then pkgs.pkgs-unstable.firefox-bin else pkgs.firefox-bin;
      policies.DisableAppUpdate = true;
      profiles = {
        xdefault = {
          isDefault = true;
          settings = {
            "app.update.auto" = false;
            "browser.uidensity" = 1;
            "browser.aboutConfig.showWarning" = false;
            "browser.contentblocking.category" = "strict";
            "browser.urlbar.showSearchSuggestionsFirst" = false;
            "layout.css.prefers-color-scheme.content-override" = 0;
            "signon.management.page.breach-alerts.enabled" = false;
            "signon.rememberSignons" = false;

            # go/
            "browser.fixup.domainwhitelist.go" = true;
          };
          extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
            bitwarden
            header-editor
            ublock-origin
            consent-o-matic
            multi-account-containers
          ];
        };
      };
    };
  };
}

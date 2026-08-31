{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.mb-type-fonts;
  root = "/var/lib/mb-type";

  # The unit materialises every entry and the store package reads only
  # activeVersion, so a bump is three ordinary deploys with no window in which
  # evaluation wants a file no deploy has written yet: add the entry, repoint
  # activeVersion, drop the old entry.
  versions = {
    "260526" = {
      urls = [
        "https://dl.jakstys.lt/mb/mb-type-260526.age"
        "https://dl2.jakstys.lt/mb/mb-type-260526.age"
      ];
      # The download loop passes no timeout of its own, so a hung-but-listening
      # first host would burn three --retry-all-errors attempts before failing
      # over. dl2 only starts serving once the dl-mirror branch lands.
      curlOpts = "--connect-timeout 15";
      hash = "sha256-4Pb/XVdqjJ0nby+CjEBQUl8fnY7l/hpMHgPFgKfxo30=";
      # Flat sha256 of the decrypted zip, from:
      #   age -d -i /run/agenix/mb-type-key mb-type-260526.age |
      #     sha256sum | cut -d' ' -f1 | xargs nix hash convert --hash-algo sha256
      plaintextHash = "sha256-F4L295N0dpp/1/dTI5mGH/D+1iQXBVe2NqLTpO1QeJ8=";
    };
  };

  activeVersion = "260526";

  zipName = version: "mb-type-${version}.zip";

  blob = version: pkgs.fetchurl { inherit (versions.${version}) urls curlOpts hash; };

  plaintextHex =
    version:
    builtins.convertHash {
      hash = versions.${version}.plaintextHash;
      hashAlgo = "sha256";
      toHashFormat = "base16";
    };

  # An eval-time fetch rather than a derivation: the plaintext may not enter the
  # build sandbox, and serving it over the network is ruled out. Pinning the flat
  # hash is what makes reading mutable state sound — the hash, not the path,
  # defines the content — and nothing checks the path first because pure
  # evaluation reports every path outside the flake as missing, while a fetcher
  # is exempt.
  #
  # The file is written by this module's own unit, so a host has to have
  # deployed the staging commit before a build for it can evaluate at all; that
  # ordering is the whole reason that commit is separate.
  #
  # Nix caches the failure as well as the file: a `hash mismatch in file
  # downloaded from file://...` keeps being reported for tarball-ttl (1h) after
  # the bytes on disk are fixed, naming a hash no longer there. `--refresh`
  # clears it. The unit only re-verifies the file at boot and at activation, so
  # an archive that goes bad in between blocks the very deploy that would repair
  # it: `systemctl restart mb-type-fonts` re-verifies and re-decrypts it.
  zip = builtins.fetchurl {
    name = zipName activeVersion;
    url = "file://${root}/${zipName activeVersion}";
    sha256 = versions.${activeVersion}.plaintextHash;
  };

  # The format directories sit below the archive's own dated top-level directory
  # and carry a parenthesised platform hint, so they are matched rather than named.
  unpacked =
    pkgs.runCommand "mb-type-${activeVersion}-unpacked"
      {
        nativeBuildInputs = [ pkgs.libarchive ];
      }
      ''
        mkdir -p $out unpacked
        bsdtar -x -f ${zip} -C unpacked --no-same-owner --no-same-permissions

        take() {
          src=$(find unpacked -mindepth 2 -maxdepth 2 -type d -name "$2" | sort | sed -n 1p)
          # Fatal, because neither fontconfig nor a woff2 consumer reports an empty one.
          [ -n "$src" ] && [ -n "$(find "$src" -name "$3" -print -quit)" ] || { echo "mb-type: no $3 under $2" >&2; exit 1; }
          cp -r --no-preserve=mode "$src" "$out/$1"
        }

        take otf 'OTF font files*' '*.otf'
        take ttf 'TTF font files*' '*.ttf'
        take woff2 'WOFF2 font files*' '*.woff2'
      '';

  fonts = pkgs.callPackage ./tree.nix {
    inherit unpacked;
    version = activeVersion;
  };
in
{
  options.mj.services.mb-type-fonts = {
    enable = lib.mkEnableOption "the MB Type font library";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default =
        if cfg.enable then
          fonts
        else
          throw ''
            mj.services.mb-type-fonts.package was read while
            mj.services.mb-type-fonts.enable is false. Enable the module.
          '';
      description = "The unpacked MB Type tree, plus the MapLibre glyph bake under glyphs/. Reading this while the module is disabled is a build error by design.";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.mb-type-key.file = ../../../secrets/mb-type-key.age;

    mj.base.unitstatus.units = [ "mb-type-fonts" ];

    # fontconfig recurses, so a tree holding otf/, ttf/ and woff2/ alongside
    # each other would surface every family three times.
    fonts.packages = [ "${unpacked}/otf" ];

    systemd.services.mb-type-fonts = {
      description = "decrypt the MB Type archives to ${root}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "mb-type";
        # The evaluator reads these as an unprivileged user; plaintext at rest
        # on the hosts that hold the key is an accepted cost.
        UMask = "0022";
      };
      script = ''
        set -euo pipefail

        ${lib.concatMapStrings (version: ''
          # The pinned hash, not a size test: evaluation reads this file by
          # content, and a truncated one is non-empty, so anything but the exact
          # bytes has to be decrypted again.
          if ! echo "${plaintextHex version}  ${root}/${zipName version}" |
              sha256sum -c --status; then
            ${pkgs.age}/bin/age -d -i ${config.age.secrets.mb-type-key.path} \
              ${blob version} >${root}/${zipName version}.tmp
            mv -T ${root}/${zipName version}.tmp ${root}/${zipName version}
          fi
        '') (lib.attrNames versions)}

        find ${root} -mindepth 1 -maxdepth 1 \
          ${lib.concatMapStringsSep " " (version: "! -name ${zipName version}") (lib.attrNames versions)} \
          -exec rm -rf {} +

        for entry in otf ttf woff2 glyphs LICENSE; do
          ln -sT "${cfg.package}/$entry" "${root}/$entry"
        done
      '';
    };
  };
}

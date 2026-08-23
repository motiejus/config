{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.mj.services.mb-type-fonts;
  root = "/var/lib/mb-type";
  # On disk, so that a later build can read the plaintext by path.
  zip = "${root}/mb-type-260526.zip";
  blob = pkgs.fetchurl {
    urls = [
      "https://dl.jakstys.lt/mb/mb-type-260526.age"
      "https://dl2.jakstys.lt/mb/mb-type-260526.age"
    ];
    # The download loop passes no timeout of its own, so a hung-but-listening
    # first host would burn three --retry-all-errors attempts before failing
    # over. dl2 only starts serving once the dl-mirror branch lands.
    curlOpts = "--connect-timeout 15";
    hash = "sha256-4Pb/XVdqjJ0nby+CjEBQUl8fnY7l/hpMHgPFgKfxo30=";
  };
in
{
  options.mj.services.mb-type-fonts.enable = lib.mkEnableOption "the MB Type font library";

  config = lib.mkIf cfg.enable {
    age.secrets.mb-type-key.file = ../../../secrets/mb-type-key.age;

    mj.base.unitstatus.units = [ "mb-type-fonts" ];

    fonts.fontconfig.localConf = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <dir>${root}/otf</dir>
      </fontconfig>
    '';

    systemd.services.mb-type-fonts = {
      description = "unpack the MB Type font library";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "mb-type";
        UMask = "0022";
      };
      # The plaintext archive is wanted on disk, so age decrypts to the zip
      # instead of into a pipe. Written as .tmp and moved into place, so a
      # partial decrypt never takes the final name; and a zip that does not
      # yield the fonts is deleted along with its generation directory, because
      # the size test that skips the decrypt cannot tell a truncated or wrong
      # archive from a good one and would fail identically on every later start.
      #
      # The generation directory is named after a store path, so each format
      # gets a stable name beside it: otf (what fontconfig reads), ttf, woff2.
      # They are searched for rather than named, because they sit below the
      # archive's own dated top-level directory. Sorted, so a future archive
      # with two matches resolves the same way every time rather than following
      # readdir order. An empty or missing one is fatal because neither a
      # dangling symlink nor fontconfig would report it.
      script = ''
        set -euo pipefail

        if [ ! -s ${zip} ]; then
          ${pkgs.age}/bin/age -d -i ${config.age.secrets.mb-type-key.path} ${blob} \
            >${zip}.tmp
          mv -T ${zip}.tmp ${zip}
        fi

        new=${root}/$(basename ${blob} .age)

        if [ ! -d "$new" ]; then
          rm -rf "$new.tmp"
          mkdir -p "$new.tmp"
          ${pkgs.libarchive}/bin/bsdtar -x -f ${zip} -C "$new.tmp" \
            --no-same-owner --no-same-permissions || {
            rm -rf ${zip} "$new.tmp"
            exit 1
          }
          mv -T "$new.tmp" "$new"
        fi

        link() {
          d=$(find "$new" -maxdepth 2 -type d -name "$2" | sort | sed -n 1p)
          [ -n "$d" ] && [ -n "$(find "$d" -name "$3" -print -quit)" ] || {
            echo "no $3 under $new" >&2
            rm -rf ${zip} "$new"
            exit 1
          }
          ln -sfnT "$d" ${root}/"$1"
        }

        link otf 'OTF font files*' '*.otf'
        link ttf 'TTF font files*' '*.ttf'
        link woff2 'WOFF2 font files*' '*.woff2'

        rm -f ${zip}.tmp
        find ${root} -maxdepth 1 -name '*-mb-type-*' ! -name "$(basename "$new")" \
          -exec rm -rf {} +
        ${pkgs.fontconfig}/bin/fc-cache -sf
      '';
    };
  };
}

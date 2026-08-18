# timelapse-merger: fill this host's empty slots from a remote timelapse tree.
#
# The video keeps one frame per 5-minute slot, so exactly one photo per slot is
# worth having and a second is worth nothing. That makes the rule simple: copy
# one photo for every slot this host has no photo for, and nothing else. Which
# host captures more often stops mattering, and so does clock drift between them.

SSH_KEY=/run/agenix/timelapse-merger-key

usage() {
  cat <<'EOF'
Usage: timelapse-merger --missing-from=[USER@]HOST YYYY-MM[-DD]

Copy photos from a remote timelapse tree into /var/lib/timelapse-r11, one for
every 5-minute slot this host has no photo for, and none for a slot it already
covers. Existing local files are never touched.

The remote is reached with /run/agenix/timelapse-merger-key, so this runs as
the timelapse-r11 user, the same one that owns the photos and takes them.
Nothing but rsync happens over that connection: the far end pins the key
to a read-only rrsync rooted at its own timelapse directory
(mj.services.timelapse-r11.readerKeys), which is why no remote path is given
here and none can be reached.

Both trees look like <root>/<camera>/<YYYY-MM-DD>/<YYYY-MM-DD>_<HH:MM:SS>.jpg

Example:
  timelapse-merger --missing-from=timelapse-r11@fwminex.jakst.vpn 2026-07
EOF
}

PERIOD=""
REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
  --missing-from=*) REMOTE="${1#*=}" ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*) die "unknown option: $1 (try --help)" ;;
  *)
    [ -z "$PERIOD" ] || die "unexpected argument: $1"
    PERIOD="$1"
    ;;
  esac
  shift
done
[ -n "$PERIOD" ] || die "missing YYYY-MM[-DD] argument (try --help)"
[ -n "$REMOTE" ] || die "--missing-from is required (try --help)"
# No path: the far end pins its own timelapse root through rrsync, and this key
# cannot reach outside it.
case "$REMOTE" in
*[\'\"\\\ /:]*) die "--missing-from takes [USER@]HOST only, no path" ;;
esac

parse_period # for the format check; this tool needs no date arithmetic
[ -r "$SSH_KEY" ] || die "cannot read $SSH_KEY (run as the timelapse-r11 user)"
find_cameras

ssh_cmd=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes)
total=0

for cam in "${cameras[@]}"; do
  # A joined month is final, and fetching a photo for it only makes the reaper
  # refuse that month forever. Coverage is judged per month across all cameras,
  # so one camera can still be waiting while this one is already done.
  month=$PERIOD
  [ "$PERIOD_MODE" = month ] || month=${PERIOD%-*}
  [ ! -e "$OUT/$cam-$month.mkv" ] || {
    log "$cam $PERIOD: $month is already a single video, nothing to backfill"
    continue
  }

  declare -A have=() take=()
  local_list="$tmp/local"
  remote_list="$tmp/remote"
  sel_list="$tmp/select"

  # Photos are named after their own date, so the period doubles as a filename
  # prefix: 2026-07 matches 2026-07*.jpg, 2026-07-03 matches 2026-07-03*.jpg.
  photos_in "$cam" "$PERIOD" -printf '%f\n' | sort >"$local_list"

  # rsync is the only thing this key may run on the far end, so the listing
  # comes from rsync too. --list-only prints the long format, reduced here to
  # basenames of files big enough to be real photos. The includes keep the far
  # end from walking years of directories.
  rsync -r --list-only -e "${ssh_cmd[*]}" \
    --include="$PERIOD*/" --include="$PERIOD*.jpg" --exclude='*' \
    "$REMOTE:/$cam/" >"$tmp/listing" || die "$cam: cannot list it on $REMOTE"
  # rsync's long listing: perms size date time name. These names never contain
  # spaces, so read splits it correctly.
  while read -r perms size _ _ name; do
    [ "${perms:0:1}" = - ] || continue         # directories
    [ "${size//,/}" -ge "$MIN_BYTES" ] || continue
    echo "$name"
  done <"$tmp/listing" | sort >"$remote_list"

  # The slots this host already has a photo for. A slot is a day plus its index
  # within that day, which needs no date arithmetic at all.
  while read -r name; do
    set_slot "$name"
    have["${name:0:10}_$slot"]=1
  done <"$local_list"

  # One remote photo per slot still empty. The list is sorted, and a photo's name
  # is its timestamp, so the first one seen for a slot is the earliest — the same
  # one the videomaker would pick.
  : >"$sel_list"
  while read -r rel; do
    name=${rel##*/}
    # shellcheck disable=SC2053 # the far end's names are untrusted; globbing is the point
    [[ $name == $PHOTO_GLOB ]] || continue
    # A photo the far end filed under the wrong day would be asked for by a path
    # that does not exist there, and rsync failing takes the whole run with it.
    [ "${rel%/*}" = "${name:0:10}" ] || {
      log "$cam: $rel is not in the day its own name gives, skipping"
      continue
    }
    set_slot "$name"
    key="${name:0:10}_$slot"
    [ -z "${have[$key]:-}" ] && [ -z "${take[$key]:-}" ] || continue
    take[$key]=1
    printf '%s/%s\n' "$cam" "$rel" >>"$sel_list"
  done <"$remote_list"

  n_sel=$(wc -l <"$sel_list")
  log "$cam $PERIOD: local=$(wc -l <"$local_list") remote=$(wc -l <"$remote_list") to-copy=$n_sel"
  [ "$n_sel" -gt 0 ] || continue

  # rsync does not reliably create the day directories from --files-from paths.
  xargs -a "$sel_list" -r dirname | sort -u | (cd "$ROOT" && xargs -r mkdir -p --)

  rsync -rt --ignore-existing --out-format='%n' \
    -e "${ssh_cmd[*]}" --files-from="$sel_list" \
    "$REMOTE:" "$ROOT/" >"$tmp/copied" || die "$cam: rsync failed"
  copied=$(grep -c '\.jpg$' "$tmp/copied" || true)
  total=$((total + copied))
  log "$cam $PERIOD: copied $copied photos"
done

# Exiting zero here is what lets the caller pass --reconciled to
# timelapse-videomaker: any failure above stops this script instead.
log "done: $total photos copied into $ROOT"

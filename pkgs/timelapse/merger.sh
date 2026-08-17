# timelapse-merger: fill real gaps in the local timelapse tree from a remote one.
#
# Only photos that land inside a genuine outage are copied. A minute or two of
# drift between two hosts is not worth a file, and a photo for a minute already
# covered locally is worse than useless: the video keeps one frame per slot, so
# it would cross the network only to be ignored.

MIN_GAP=10 # minutes; shorter holes make no visible difference in the video
SSH_KEY=/run/agenix/timelapse-merger-key

usage() {
  cat <<'EOF'
Usage: timelapse-merger --missing-from=[USER@]HOST YYYY-MM[-DD]

Copy photos from a remote timelapse tree into /var/lib/timelapse-r11, but only
where the local tree is missing more than 10 minutes in a row, and only for
minutes the local tree does not already cover. Existing local files are never
touched.

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

export TZ=UTC
parse_period
[ -r "$SSH_KEY" ] || die "cannot read $SSH_KEY (run as the timelapse-r11 user)"
find_cameras

ssh_cmd=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes)
total=0

for cam in "${cameras[@]}"; do
  local_list="$tmp/local"
  remote_list="$tmp/remote"
  sel_list="$tmp/select"

  # Photos are named after their own date, so the period doubles as a filename
  # prefix: 2026-07 matches 2026-07*.jpg, 2026-07-03 matches 2026-07-03*.jpg.
  find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f \
    -name "$PERIOD*.jpg" -size "+$((MIN_BYTES - 1))c" -printf '%f\n' |
    sort >"$local_list"

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
    echo "${name##*/}"
  done <"$tmp/listing" | sort >"$remote_list"

  gawk -v start="$START" -v end="$END" -v mingap="$((MIN_GAP * 60))" -v cam="$cam" '
    function ts(fn) {
      return mktime(substr(fn, 1, 4) " " substr(fn, 6, 2) " " substr(fn, 9, 2) " " \
                    substr(fn, 12, 2) " " substr(fn, 15, 2) " " substr(fn, 18, 2))
    }
    # Pass 1: local coverage, as a timeline and as a set of covered minutes.
    ARGIND == 1 {
      t = ts($0)
      if (t >= start && t < end) { local_ts[++n] = t; covered[int(t / 60)] = 1 }
      next
    }
    # Pass 2 starts: turn local coverage into the gaps worth filling. A photo
    # exactly at the period start belongs to the leading gap, hence start - 1.
    ARGIND == 2 && FNR == 1 {
      prev = start - 1
      for (i = 1; i <= n; i++) {
        if (local_ts[i] - prev > mingap) { lo[++g] = prev; hi[g] = local_ts[i] }
        prev = local_ts[i]
      }
      if (end - prev > mingap) { lo[++g] = prev; hi[g] = end }
    }
    ARGIND == 2 {
      t = ts($0)
      if (t < start || t >= end) next
      # One frame per slot: a minute already covered locally cannot use another.
      if (int(t / 60) in covered) next
      for (i = 1; i <= g; i++)
        if (t > lo[i] && t < hi[i]) { print cam "/" substr($0, 1, 10) "/" $0; break }
    }
  ' "$local_list" "$remote_list" >"$sel_list"

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

# Proof for timelapse-videomaker that this period has been reconciled with the
# other host, which is what it requires before joining a month for good. Written
# last on purpose: any failure above exits non-zero and leaves none.
mkdir -p "$MERGED"
: >"$MERGED/$PERIOD"

log "done: $total photos copied into $ROOT"

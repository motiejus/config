# timelapse-daily: keep the video archive caught up with the stills.
#
# Four things, oldest work first:
#
#   0. backfill the months that can still change from the other host
#   1. encode every finished day whose month is not yet a single video
#   2. join a finished month once all of its days exist
#   3. drop the day videos of a month that has been joined
#
# Every step is safe to interrupt and safe to repeat: work already done is
# recognised by the files it left behind, and nothing is deleted until the video
# replacing it has been checked. Doing nothing is the normal outcome.
#
# Days with no photos at all are encoded too, as a full day of greyed picture
# with a red clock. That is what keeps a month joinable, and it is why an outage
# straddling the turn of a month needs no special handling: the days either side
# are ordinary days that happen to have no photos.

usage() {
  cat <<'EOF'
Usage: timelapse-daily [--missing-from=[USER@]HOST]

Encode any finished day that has no video, join a month once all its days are
encoded, and remove the day videos of a month that has been joined. Intended to
run daily. Deleting stills is timelapse-reap's job.

  --missing-from=[USER@]HOST   first run timelapse-merger against HOST for every
                               month that is not yet a single video

Without --missing-from no month is joined at all: a month video is final, and
making one while the other host is unreachable would freeze an outage that could
still have been filled in.
EOF
}

MERGE_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
  --missing-from=*) MERGE_FROM="${1#*=}" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unexpected argument: $1 (try --help)" ;;
  esac
  shift
done

export TZ=UTC
find_cameras

# A month may only be joined on the heels of a successful backfill, so the proof
# timelapse-merger leaves behind never outlives one run of this tool. Without
# --missing-from nothing writes one and no month is ever joined, which is the
# safe way round: photos pile up, none are lost.
rm -rf "$MERGED"

# Only days that have ended can be encoded.
today=$(date -u +%F)
last_day=$(date -u -d "@$(($(date -u -d "$today 00:00:00" +%s) - 86400))" +%F)

# Start at the oldest day any camera still has stills for; anything older has
# already become video and had its stills reaped. Round back to the 1st of that
# month: a month is only joinable once every one of its days is a video, so the
# days before the camera was installed have to be encoded too, black.
oldest_photo_day() { # cam
  local d
  while read -r d; do
    [ -z "$(list_photos "$ROOT/$1/$d")" ] || {
      echo "$d"
      return
    }
  done < <(list_days "$ROOT/$1" | sort)
}
first_day=$(for cam in "${cameras[@]}"; do oldest_photo_day "$cam"; done | sort | head -n1)
[ -n "$first_day" ] || {
  log "no stills anywhere, nothing to do"
  exit 0
}
first_day="${first_day%-*}-01"

# 0. Backfill, oldest month first. Only a month that is not yet a single video
# can still take photos, so those are the only ones worth asking about; a joined
# month is final. Asking again every night is what makes a late outage on the
# other host heal itself.
#
# A failure here stops the whole run on purpose. Encoding is idempotent and
# catches up tomorrow, whereas a month joined while the other host was
# unreachable is permanent: its holes can never be filled in.
this_month=$(date -u +%Y-%m)
m="${first_day%-*}"
while [ -n "$MERGE_FROM" ] && [[ "$m" < "$this_month" || "$m" == "$this_month" ]]; do
  for cam in "${cameras[@]}"; do
    [ -e "$OUT/$cam-$m.mkv" ] || {
      timelapse-merger --missing-from="$MERGE_FROM" "$m"
      break
    }
  done
  m=$(next_month "$m")
done

# 1. Encode. timelapse-videomaker decides per camera what is actually needed,
# including whether a day must be redone because photos turned up for slots it
# calls missing, so it is simply asked about every day.
d="$first_day"
while [[ "$d" < "$last_day" || "$d" == "$last_day" ]]; do
  timelapse-videomaker "$d"
  d=$(date -u -d "@$(($(date -u -d "$d 00:00:00" +%s) + 86400))" +%F)
done

# 2. Join whole months, discovered from the day videos on disk so a backlog is
# worked through oldest first.
mapfile -t months < <(find "$DAYS" -maxdepth 1 -name '[!.]*.mkv' -printf '%f\n' 2>/dev/null |
  sed -E 's/^.*-([0-9]{4}-[0-9]{2})-[0-9]{2}\.mkv$/\1/' | sort -u)
for m in "${months[@]}"; do
  [ "$m" != "$(date -u +%Y-%m)" ] || continue # not over yet
  timelapse-videomaker "$m"
done

# 3. Drop the day videos of a month that is now a single video. Safe to do
# unchecked: the stills are still on disk until timelapse-reap has looked at the
# month and agreed, so a day can always be encoded again.
for m in "${months[@]}"; do
  for cam in "${cameras[@]}"; do
    [ -e "$OUT/$cam-$m.mkv" ] || continue
    mapfile -t dayfiles < <(find "$DAYS" -maxdepth 1 -name "$cam-$m-[0-9][0-9].mkv" | sort)
    [ "${#dayfiles[@]}" -gt 0 ] || continue
    for f in "${dayfiles[@]}"; do rm -f "$f" "${f%.mkv}.tsv"; done
    log "$cam $m: dropped ${#dayfiles[@]} day videos, the month video covers them"
  done
done
rmdir "$DAYS" 2>/dev/null || true

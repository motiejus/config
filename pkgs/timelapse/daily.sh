# timelapse-daily: keep the video archive caught up with the stills.
#
# One whole month at a time, oldest first, and always in this order: merge that
# month from the other host, encode the days it has no video for, join it, then
# drop the day videos the month video now covers.
#
# Both hosts hold every photograph they will ever hold for a day within minutes
# of that day ending, so a month merged after it is over has nothing more coming:
# every day encoded from it is final, and a month whose day videos all exist is
# reconciled by induction and joinable without asking the other host again. That
# is why nothing here revisits a day or a month, and why a merge that fails stops
# the run — nothing after it can be encoded safely. Encoding is idempotent, the
# failure is mailed, and tomorrow's run starts over.
#
# The current month is merged and its finished days encoded, but never joined: it
# is not over. Deleting stills is timelapse-reap's job.
#
# Days with no photos at all are encoded too, as a full day of greyed picture with
# the outage named in the subtitles. That is what keeps a month joinable, and it is
# why an outage straddling the turn of a month needs no special handling: the days
# either side are ordinary days that happen to have no photos.

usage() {
  cat <<'EOF'
Usage: timelapse-daily --missing-from=[USER@]HOST

Merge every month that is not yet a single video from HOST, encode the days that
have ended, join a month once all of its days are encoded, and drop the day
videos a month video covers. Intended to run daily. Deleting stills is
timelapse-reap's job.

  --missing-from=[USER@]HOST   the other host keeping a copy of these stills

Required, and not a flag to work around: a month video is final, so a day is
encoded only after the month it belongs to has been asked of the other host.
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
[ -n "$MERGE_FROM" ] || die "--missing-from is required (try --help)"

find_cameras

# Start at the oldest month any camera still has photographs for; anything older
# has already become video and had its stills reaped. Whole months, because a
# month is only joinable once every one of its days is a video, so the days
# before the camera was installed have to be encoded too, black.
first_month=$(photo_months)
[ -n "$first_month" ] || {
  log "no stills anywhere, nothing to do"
  exit 0
}
first_month="${first_month%%$'\n'*}"
today=$(date -u +%F)
this_month=${today%-*}

# The days of month $1 that have ended, oldest first. PERIOD and days are local,
# so the caller's own keep whatever they held while parse_period spans the month.
ended_days() { # month
  local PERIOD=$1 days d
  parse_period
  for d in "${days[@]}"; do
    [[ "$d" < "$today" ]] || break
    echo "$d"
  done
}

# The day videos a month video has taken over. Safe unchecked: the stills are
# still on disk until timelapse-reap has looked at the month and agreed, so a day
# can always be encoded again.
drop_day_videos() { # month
  local cam dayfiles
  # The directory is removed once the last day video in it goes, and find would
  # complain about its absence every night after.
  [ -d "$DAYS" ] || return 0
  for cam in "${cameras[@]}"; do
    [ -e "$OUT/$cam-$1.mkv" ] || continue
    mapfile -t dayfiles < <(find "$DAYS" -maxdepth 1 -name "$cam-$1-[0-9][0-9].mkv" | sort)
    [ "${#dayfiles[@]}" -gt 0 ] || continue
    rm -f "${dayfiles[@]}"
    log "$cam $1: dropped ${#dayfiles[@]} day videos, the month video covers them"
  done
}

m="$first_month"
# A photograph dated in the future would otherwise leave nothing for the loop to
# do and nothing said about it.
[[ ! "$m" > "$this_month" ]] || m="$this_month"
while [[ ! "$this_month" < "$m" ]]; do
  if [[ "$m" < "$this_month" ]] && joined "$m"; then
    drop_day_videos "$m"
  else
    timelapse-merger --missing-from="$MERGE_FROM" "$m" ||
      die "$m: nothing merged, so nothing of it can be encoded"
    # A list, not a pipe: ffmpeg reads stdin, and a while-read loop around it
    # would lose every day after the first.
    mapfile -t ended < <(ended_days "$m")
    for d in "${ended[@]}"; do timelapse-videomaker "$d"; done
    [[ "$m" < "$this_month" ]] || break # this month is not over: never joined
    timelapse-videomaker "$m"
    drop_day_videos "$m"
  fi
  m=$(next_month "$m")
done

rmdir "$DAYS" 2>/dev/null || true

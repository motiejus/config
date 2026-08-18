# timelapse-reap: delete a period's stills, once its video is proven good.
#
# Deliberately a separate tool from timelapse-videomaker: the thing that creates
# an artifact is the worst possible judge of whether it is worth keeping. The
# checks here stand on their own — they read only the video, its manifest and
# the photos, and would catch a bad video however it came to be.
#
# Sampling means most photos are NOT in the video: at one frame per 5 minutes,
# four of every five one-minute captures are dropped on purpose. Those are
# deleted too. That is the trade this tool exists to make, so it says so out
# loud and refuses unless everything below holds.

# Whole months of stills kept behind the current one, purely so recent days can
# still be looked at as photographs. Nothing repairs a video with them: a month
# is reconciled with the other host and joined long before this.
KEEP_MONTHS=3

usage() {
  cat <<EOF
Usage: timelapse-reap [--dry-run] [YYYY-MM[-DD]]

Delete the stills for a period whose video is finished and verified. With no
period, every month that is old enough to let go of: the current month and the
$KEEP_MONTHS before it are always kept as photos, and a month still waiting for
its video is left alone.

For each camera, from scratch:

  * the video carries its own frame manifest
  * the video holds one frame per manifest row, and reads without error
  * a sample of frames still looks like the photo the manifest names
  * every 5-minute slot with photos on disk is a "photo" slot in the manifest,
    so nothing that arrived after the encode is thrown away

Only then are the period's photos deleted, including the ones between samples
that the video never contained. Files whose names are not timestamps are not
photographs to any of these tools: never counted, never deleted, never in a
video. Rename them if you want them archived.

  -n, --dry-run   run every check and report, delete nothing
EOF
}

PERIOD=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
  -n | --dry-run) DRY_RUN=1 ;;
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
find_cameras

# Months that still hold photographs and are far enough in the past to give up,
# oldest first. A month whose video is not finished yet is skipped rather than
# refused: it is timelapse-daily's turn, not an error. Logs go to stderr, the
# months themselves to stdout.
due_months() {
  local newest month i
  # The current month and KEEP_MONTHS whole ones behind it are kept.
  i=$((10#$(date -u +%Y) * 12 + 10#$(date -u +%m) - 1 - KEEP_MONTHS - 1))
  newest=$(printf '%d-%02d' $((i / 12)) $((i % 12 + 1)))
  while read -r month; do
    [[ "$month" < "$newest" || "$month" == "$newest" ]] || continue
    joined "$month" || {
      log "$month: old enough to reap, but not joined into a video yet" >&2
      continue
    }
    echo "$month"
  done < <(photo_months)
}

reap_camera() { # cam
  local cam="$1" video manifest n_photos strays packets missed kept deleted

  manifest="$tmp/manifest" # filled from the video itself, below
  if [ "$PERIOD_MODE" = month ]; then
    video="$OUT/$cam-$PERIOD.mkv"
  else
    video="$DAYS/$cam-$PERIOD.mkv"
  fi

  n_photos=$(photos_in "$cam" "$PERIOD" | wc -l)
  [ "$n_photos" -gt 0 ] || {
    log "$cam $PERIOD: no stills left, nothing to do"
    return 0
  }
  # Anything named otherwise is not a photograph to these tools, so it is neither
  # in the video nor ever deleted. Say so out loud: a silent write-off is how real
  # pictures would be lost.
  strays=$(find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f -name "*.jpg" \
    ! -name "$PHOTO_GLOB" -path "*/$PERIOD*" | wc -l)
  [ "$strays" -eq 0 ] ||
    log "$cam $PERIOD: $strays files are not named as timestamps, so they are in no video; rename them to keep them"

  [ -f "$video" ] || die "$cam $PERIOD: $video does not exist; make the video first"

  # Everything below is judged against the manifest the video carries, which is
  # the only copy of it there is.
  manifest_of "$video" "$manifest" ||
    die "$cam $PERIOD: $(basename "$video") carries no manifest of its own"
  [ "$(stat -c %s "$manifest")" -eq "$((NSLOTS * MANIFEST_ROW))" ] ||
    die "$cam $PERIOD: the manifest in the video is not $NSLOTS fixed-width rows"
  # And every 288-row block has to be the day it sits at: nothing else here ties
  # the video to what it claims to be, so one renamed, restored into the wrong
  # place, or joined from swapped days would otherwise verify against its own
  # photographs and delete somebody else's. Per day rather than per period,
  # because the names carry the day and a swap inside a month is invisible to a
  # month-wide check.
  [ "$(awk -v days="${days[*]}" -v n="$SLOTS_PER_DAY" \
    'BEGIN { split(days, d, " ") }
     $2 == "P" && substr($3, 1, 10) != d[int(($1 + 0) / n) + 1]' \
    "$manifest" | wc -l)" -eq 0 ] ||
    die "$cam $PERIOD: the manifest in the video is not the days of $PERIOD"

  # Demuxing every packet both counts the frames and reads the whole file, so
  # btrfs checksums each extent on the way past: a decode of every frame costs
  # minutes per month and catches nothing this does not.
  packets=$(ffprobe -v error -count_packets -select_streams v:0 \
    -show_entries stream=nb_read_packets -of csv=p=0 "$video")
  [ "$packets" = "$NSLOTS" ] || die "$cam $PERIOD: $packets frames, expected $NSLOTS"

  # Every slot with a photo on disk must be a photo slot in the video. This is
  # what catches a video encoded before the stills were complete, e.g. before
  # timelapse-merger backfilled an outage from the other host.
  photo_slots "$manifest" >"$tmp/invideo"
  slots_on_disk "$cam" >"$tmp/ondisk"
  missed=$(comm -13 "$tmp/invideo" "$tmp/ondisk" | wc -l)
  [ "$missed" -eq 0 ] ||
    die "$cam $PERIOD: $missed slots have photos on disk that the video does not use.
  Photos arrived after it was made, most likely from timelapse-merger. Delete
  $video, then run timelapse-daily to build it again."

  verify_pixels "$video" "$manifest" "$cam"

  kept=$(wc -l <"$tmp/invideo")
  log "$cam $PERIOD: video is good; $n_photos stills, of which $kept are in it as frames"
  [ "$DRY_RUN" -eq 0 ] || {
    log "$cam $PERIOD: dry run, deleting nothing"
    return 0
  }
  # One pass takes the failed captures too: they are photographs to nobody, so
  # nothing else would remove them, and one keeps its day directory alive for good.
  deleted=$(find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f \
    -name "$PERIOD*" -name "$PHOTO_GLOB" -printf . -delete | wc -c)
  # Work files from an encode that was killed between writing and renaming.
  rm -f "$DAYS/.$cam-$PERIOD"*.part.mkv "$OUT/.$cam-$PERIOD"*.part.mkv
  # Only this period's day directories: an empty one elsewhere in the tree may
  # be today's, made seconds ago by the capture unit and still waiting for its
  # first photo.
  find "$ROOT/$cam" -mindepth 1 -maxdepth 1 -type d -name "$PERIOD*" -empty -delete
  log "$cam $PERIOD: deleted $deleted files, $n_photos of them photographs"
}

periods=("$PERIOD")
[ -n "$PERIOD" ] || mapfile -t periods < <(due_months)
[ "${#periods[@]}" -gt 0 ] || log "no month is both old enough to reap and finished as video"

failed=0
for PERIOD in "${periods[@]}"; do
  parse_period
  for cam in "${cameras[@]}"; do (reap_camera "$cam") || failed=1; done
done
exit "$failed"

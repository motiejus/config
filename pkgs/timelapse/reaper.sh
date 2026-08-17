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

  * the video and its .frames.tsv exist and agree on length
  * every frame of the video decodes
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
  local cam="$1" video manifest n_photos strays decoded missed kept

  if [ "$PERIOD_MODE" = month ]; then
    video="$OUT/$cam-$PERIOD.mkv"
    manifest="$OUT/$cam-$PERIOD.frames.tsv"
  else
    video="$DAYS/$cam-$PERIOD.mkv"
    manifest="$DAYS/$cam-$PERIOD.tsv"
  fi

  n_photos=$(photos_in "$cam" "$PERIOD" | wc -l)
  [ "$n_photos" -gt 0 ] || {
    log "$cam $PERIOD: no stills left, nothing to do"
    return 0
  }
  # Anything named otherwise is not a photograph to these tools, so it is neither
  # in the video nor ever deleted. Say so: on 2025-04-06 that is 1343 real
  # pictures per camera, and a silent write-off is how they would be lost.
  strays=$(find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f -name "*.jpg" \
    ! -name "$PHOTO_GLOB" -path "*/$PERIOD*" | wc -l)
  [ "$strays" -eq 0 ] ||
    log "$cam $PERIOD: $strays files are not named as timestamps, so they are in no video; rename them to keep them"

  [ -f "$video" ] || die "$cam $PERIOD: $video does not exist; make the video first"
  [ -f "$manifest" ] || die "$cam $PERIOD: $manifest does not exist"
  [ "$(grep -vc '^#' "$manifest")" -eq "$NSLOTS" ] ||
    die "$cam $PERIOD: manifest is not $NSLOTS rows"

  log "$cam $PERIOD: decoding every frame of $(basename "$video")"
  decoded=$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of csv=p=0 "$video")
  [ "$decoded" = "$NSLOTS" ] || die "$cam $PERIOD: only $decoded of $NSLOTS frames decode"
  ffmpeg -v error -xerror -i "$video" -f null - ||
    die "$cam $PERIOD: the video does not decode cleanly"

  # Every slot with a photo on disk must be a photo slot in the video. This is
  # what catches a video encoded before the stills were complete, e.g. before
  # timelapse-merger backfilled an outage from the other host.
  # comm compares as text, so both sides sort the same plain way. The grep
  # matches nothing when the whole period is missing, which is not an error.
  { grep -P '\tphoto\t' "$manifest" || true; } | cut -f1 | sort >"$tmp/invideo"
  slots_on_disk "$cam" >"$tmp/ondisk"
  missed=$(comm -13 "$tmp/invideo" "$tmp/ondisk" | wc -l)
  [ "$missed" -eq 0 ] ||
    die "$cam $PERIOD: $missed slots have photos on disk that the video does not use.
  Photos arrived after it was made, most likely from timelapse-merger. Delete
  $video and its .frames.tsv, then run timelapse-daily to build it again."

  verify_pixels "$video" "$manifest" "$cam"

  kept=$(wc -l <"$tmp/invideo")
  log "$cam $PERIOD: video is good; $n_photos stills, of which $kept are in it as frames"
  [ "$DRY_RUN" -eq 0 ] || {
    log "$cam $PERIOD: dry run, deleting nothing"
    return 0
  }
  photos_in "$cam" "$PERIOD" -delete
  # Only this period's day directories: an empty one elsewhere in the tree may
  # be today's, made seconds ago by the capture unit and still waiting for its
  # first photo.
  find "$ROOT/$cam" -mindepth 1 -maxdepth 1 -type d -name "$PERIOD*" -empty -delete
  log "$cam $PERIOD: deleted $n_photos stills"
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

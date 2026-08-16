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

usage() {
  cat <<'EOF'
Usage: timelapse-reap [--dry-run] YYYY-MM[-DD]

Delete the stills for a period whose video is finished and verified. For each
camera, from scratch:

  * the video and its .frames.tsv exist and agree on length
  * every frame of the video decodes
  * a sample of frames still looks like the photo the manifest names
  * every 5-minute slot with photos on disk is a "photo" slot in the manifest,
    so nothing that arrived after the encode is thrown away

Only then are the period's photos deleted, including the ones between samples
that the video never contained.

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
[ -n "$PERIOD" ] || die "missing YYYY-MM[-DD] argument (try --help)"

export TZ=UTC
parse_period
[ -d "$ROOT" ] || die "no such directory: $ROOT"
find_cameras

# Slots of the whole period that have a photo on disk, ascending. Slots are
# numbered from the start of the period, so each day contributes its own 288.
slots_on_disk() { # cam
  local day f i=0
  for day in "${days[@]}"; do
    while read -r f; do
      set_slot "$f"
      echo $((i * SLOTS_PER_DAY + slot))
    done < <(list_photos "$ROOT/$1/$day")
    i=$((i + 1))
  done | sort -un
}

reap_camera() { # cam
  local cam="$1" video manifest n_photos decoded missed kept

  if [ "$PERIOD_MODE" = month ]; then
    video="$OUT/$cam-$PERIOD.mkv"
    manifest="$OUT/$cam-$PERIOD.frames.tsv"
  else
    video="$DAYS/$cam-$PERIOD.mkv"
    manifest="$DAYS/$cam-$PERIOD.tsv"
  fi

  n_photos=$(find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f -name "$PERIOD*.jpg" 2>/dev/null | wc -l)
  [ "$n_photos" -gt 0 ] || {
    log "$cam $PERIOD: no stills left, nothing to do"
    return 0
  }
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
  slots_on_disk "$cam" | sort >"$tmp/ondisk"
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
  find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f -name "$PERIOD*.jpg" -delete
  find "$ROOT/$cam" -mindepth 1 -maxdepth 1 -type d -empty -delete
  log "$cam $PERIOD: deleted $n_photos stills"
}

failed=0
for cam in "${cameras[@]}"; do (reap_camera "$cam") || failed=1; done
exit "$failed"

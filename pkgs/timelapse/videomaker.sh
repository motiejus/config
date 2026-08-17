# timelapse-videomaker: turn stills into archival video, a day at a time.
#
#   timelapse-videomaker 2026-07-03   encode that one day
#   timelapse-videomaker 2026-07      join that month's days into one video
#
# The timeline is wall-clock: frame N is 5-minute slot N of the period, always.
# Where several photos fall in one slot the earliest wins; the rest are not in
# the video. A photo stands in for up to HOLD slots of missing ones, beyond
# which the picture is greyed out and stamped with a red clock, so an outage
# looks like an outage instead of a frozen camera. A day with no photos at all
# is a full day of that treatment, greyed over the last picture the camera
# managed to take, which may be days or months earlier.
#
# Both the encoder's input list and the frame ranges the greying filter is
# switched on for are derived from the manifest, so the picture cannot disagree
# with it. That is a mistake this code has made before, back when the two were
# built side by side.
#
# This tool does not check its own work: everything that could be wrong with a
# video is checked by timelapse-reap, before it deletes anything. Nothing here
# is irreversible while the stills are still on disk.
#
# No tuning knobs on purpose. Measured on this footage (2026-08): 5-minute
# sampling is 4.2x smaller than 1-minute, because a static camera compresses
# extremely well minute-to-minute and much less well at 5. For the same reason
# there is no denoise: at 5 minutes it saved 14% and smeared blocks across flat
# walls.

CRF=35
PRESET=2
FPS=24
DUR=0.041666667      # one frame at 24 fps, written out because FPS is not a knob
HOLD=2               # slots one photo may cover before the picture is marked missing
LOCAL_TZ=Europe/Vilnius # the red clock burnt into missing frames reads local time

usage() {
  cat <<'EOF'
Usage: timelapse-videomaker YYYY-MM-DD                encode one day
       timelapse-videomaker --reconciled YYYY-MM      join that month for good

  --reconciled   the other host has just been asked for everything it holds for
                 this month, so the joined video may be made final. Required to
                 join, because a joined month is never rebuilt. By hand:
                 timelapse-merger --missing-from=HOST 2026-07 &&
                   timelapse-videomaker --reconciled 2026-07

Day videos go to /var/lib/timelapse-r11/videos/days/<camera>-<date>.mkv and
month videos to /var/lib/timelapse-r11/videos/<camera>-<month>.mkv, each with a
.frames.tsv naming the source photo behind every frame, also attached inside the
.mkv.

One frame per 5 minutes of wall-clock time, so a day is 288 frames and one
second of video is two hours. Missing stretches keep the pace: the last photo is
held for up to 10 minutes, then greyed out and stamped with a red Europe/Vilnius
clock until the camera comes back. A day with no photos at all is greyed end to
end over the last picture the camera took, whenever that was.

A finished video is not rebuilt, except that a day is re-encoded when photos
have appeared for slots it calls missing. Joining a month needs every one of its
days. timelapse-daily normally drives both steps; timelapse-reap checks the
result.
EOF
}

PERIOD=""
RECONCILED=0
while [ $# -gt 0 ]; do
  case "$1" in
  --reconciled) RECONCILED=1 ;;
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

parse_period
[ "$END" -le "$(date -u +%s)" ] || die "period $PERIOD has not finished yet; wait until it has"
find_cameras

# Width, height and pixel format of a photo. The black filler has to match all
# three: a change mid-concat reinitialises the filter graph, setpts starts
# counting from zero again, and cfr drops the frame whose timestamp went
# backwards. Cameras do not all encode their JPEGs the same way, so read it.
geometry() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=s=,:p=0 "$1"
}

# Newest photo strictly before $2, as <date>/<file>, or nothing. Crosses month
# and year boundaries, which is what lets an outage spanning the turn of a month
# keep showing the last picture from before it started.
previous_photo() { # cam day
  local d f
  while read -r d; do
    [[ "$d" < "$2" ]] || continue
    f=$(list_photos "$ROOT/$1/$d" | tail -1)
    [ -z "$f" ] || {
      echo "$d/$f"
      return
    }
  done < <(list_days "$ROOT/$1" | sort -r)
}

# One line per slot: index, clock, status, source. The only place the
# photo/held/missing decision is made.
write_manifest() { # cam day seed seed_age
  local day="$2" last="$3" f i rel status
  local last_slot=$((-1000000))
  local -A src=()
  [ -z "$last" ] || last_slot=$((-$4))

  while read -r f; do
    set_slot "$f"
    [ -n "${src[$slot]:-}" ] || src[$slot]="$day/$f"
  done < <(list_photos "$ROOT/$1/$day")

  for ((i = 0; i < SLOTS_PER_DAY; i++)); do
    if [ -n "${src[$i]:-}" ]; then
      rel=${src[$i]}
      last=$rel
      last_slot=$i
      status=photo
    elif [ -n "$last" ] && ((i - last_slot < HOLD)); then
      rel=$last
      status=held
    else
      rel=$last
      status=missing
    fi
    printf '%d\t%02d:%02d\t%s\t%s\n' \
      "$i" $((i * SLOT_MINUTES / 60)) $((i * SLOT_MINUTES % 60)) "$status" "${rel:--}"
  done
}

manifest_to_concat() { # cam black < manifest
  local rel path
  echo "ffconcat version 1.0"
  while IFS=$'\t' read -r _ _ _ rel; do
    if [ "$rel" = - ]; then path=$2; else path=$ROOT/$1/$rel; fi
    printf "file '%s'\nduration %s\n" "$path" "$DUR"
  done
}

manifest_to_enable() { # < manifest
  local slot status start=-1 prev=-1 out=""
  while IFS=$'\t' read -r slot _ status _; do
    if [ "$status" = missing ]; then
      [ "$start" -ge 0 ] || start=$slot
      prev=$slot
    elif [ "$start" -ge 0 ]; then
      out="$out+between(n\\,$start\\,$prev)"
      start=-1
    fi
  done
  [ "$start" -lt 0 ] || out="$out+between(n\\,$start\\,$prev)"
  echo "${out#+}"
}

encode_day() { # cam day
  local cam="$1" day="$2"
  local video="$DAYS/$cam-$day.mkv" manifest_final="$DAYS/$cam-$day.tsv"
  local manifest="$tmp/manifest" concat="$tmp/concat"
  local seed seed_age=0 ref w h pix_fmt black vf enable stamp work

  if [ -e "$video" ] && [ -e "$manifest_final" ]; then
    # comm compares as text, so both sides sort the same plain way. The grep
    # matches nothing on an all-missing day, which is not an error.
    slots_on_disk "$cam" >"$tmp/ondisk"
    { grep -P '\tphoto\t' "$manifest_final" || true; } | cut -f1 | sort >"$tmp/invideo"
    [ -n "$(comm -13 "$tmp/invideo" "$tmp/ondisk")" ] || return 0
    log "$cam $day: photos appeared for slots it calls missing, re-encoding"
  fi

  local day_epoch
  day_epoch=$(date -u -d "$day 00:00:00" +%s)
  seed=$(previous_photo "$cam" "$day")
  [ -z "$seed" ] ||
    seed_age=$(((day_epoch -
      $(date -u -d "${seed:11:10} ${seed:22:2}:${seed:25:2}:${seed:28:2}" +%s) +
      60 * SLOT_MINUTES - 1) / 60 / SLOT_MINUTES))

  ref=$(list_photos "$ROOT/$cam/$day")
  if [ -n "$ref" ]; then
    ref="$ROOT/$cam/$day/${ref%%$'\n'*}"
  elif [ -n "$seed" ]; then
    ref="$ROOT/$cam/$seed"
  else
    # Nothing here and nothing before: a day from before the camera existed. It
    # still gets a video, black end to end, so its month can be joined. Any
    # photo will do, since only its geometry is read. Assigned before it is
    # trimmed because head would close the pipe and take sort down with it.
    ref=$(photos_in "$cam" "" | sort)
    [ -n "$ref" ] || {
      log "$cam $day: this camera has no photos at all, skipping"
      return 0
    }
    ref="${ref%%$'\n'*}"
  fi
  IFS=, read -r w h pix_fmt <<<"$(geometry "$ref")"
  black="$tmp/black.jpg"
  ffmpeg -v error -y -f lavfi -i "color=black:s=${w}x${h}" -pix_fmt "$pix_fmt" -frames:v 1 "$black"

  write_manifest "$cam" "$day" "$seed" "$seed_age" >"$manifest"
  manifest_to_concat "$cam" "$black" <"$manifest" >"$concat"
  enable=$(manifest_to_enable <"$manifest")

  vf=""
  if [ -n "$enable" ]; then
    # The clock is drawn from the frame's presentation time, so ffmpeg does the
    # local-time conversion and gets the two DST days a year right by itself,
    # including the date rolling over at 22:00 or 21:00 UTC. That needs pts to
    # be real seconds while drawtext runs, hence the two setpts either side.
    # Only the colon inside the strftime format is escaped.
    stamp="$tmp/stamp.txt"
    printf '%s' "%{pts:localtime:$day_epoch:%Y-%m-%d %H\\:%M %Z}   NO DATA" >"$stamp"
    vf="setpts=N*$((SLOT_MINUTES * 60))/TB"
    vf="$vf,hue=s=0:enable=$enable,eq=brightness=-0.25:contrast=0.85:enable=$enable"
    # Opaque box, not a translucent one: on a dimmed static frame the encoder
    # will happily spend nothing on a single changed digit, and the clock then
    # lags a frame behind. Flat black behind bright red is cheap to code and
    # survives crf 35.
    vf="$vf,drawtext=fontfile=$TIMELAPSE_FONT:textfile=$stamp:fontcolor=red"
    vf="$vf:fontsize=h/18:box=1:boxcolor=black:boxborderw=18"
    vf="$vf:x=(w-text_w)/2:y=h-text_h-40:enable=$enable"
    vf="$vf,setpts=N/$FPS/TB,"
  fi
  vf="${vf}format=yuv420p10le"

  local progress=(-nostats)
  [ ! -t 2 ] || progress=(-stats -stats_period 10)
  work="$DAYS/.$cam-$day.$$.part.mkv"
  log "$cam $day: encoding into $SLOTS_PER_DAY frames"
  TZ=$LOCAL_TZ ffmpeg -hide_banner -loglevel warning "${progress[@]}" -y \
    -f concat -safe 0 -i "$concat" -r "$FPS" -fps_mode cfr -vf "$vf" \
    -c:v libsvtav1 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le -g $((FPS * 10)) \
    -attach "$manifest" -metadata:s:t:0 mimetype=text/plain \
    -metadata:s:t:0 filename="$cam-$day.frames.tsv" -metadata "title=$cam $day" \
    "$work" || {
    rm -f "$work"
    die "$cam $day: encode failed, see ffmpeg above"
  }
  # One frame per manifest row, checked while the work file can still be thrown
  # away: cfr silently drops a frame whose timestamp went backwards, and once the
  # month is joined nothing will rebuild the day.
  [ "$(ffprobe -v error -count_packets -select_streams v:0 \
    -show_entries stream=nb_read_packets -of csv=p=0 "$work")" = "$(wc -l <"$manifest")" ] || {
    rm -f "$work"
    die "$cam $day: encoder produced the wrong number of frames, most likely a
  photo of a different size or pixel format than ${ref##*/} among this day's own
  or in the last one before it"
  }

  # Manifest first: a video without one is treated as unfinished.
  cp "$manifest" "$manifest_final"
  mv "$work" "$video"
  log "$cam $day: wrote $video ($(du -h "$video" | cut -f1))"
}

join_month() { # cam
  local cam="$1" day i=0
  local video="$OUT/$cam-$PERIOD.mkv" manifest="$tmp/month.tsv" work="$OUT/.$cam-$PERIOD.$$.part.mkv"

  [ ! -e "$video" ] || {
    log "$cam $PERIOD: already joined, skipping"
    return 0
  }
  # This video is final: nothing rebuilds a joined month, so its holes can never
  # be filled in afterwards. Only a caller that has just reconciled the month
  # with the other host may ask for it.
  [ "$RECONCILED" = 1 ] || {
    log "$cam $PERIOD: not joining, --reconciled not given (merge from the other host first)"
    return 0
  }
  for day in "${days[@]}"; do
    [ -e "$DAYS/$cam-$day.mkv" ] && [ -e "$DAYS/$cam-$day.tsv" ] || {
      log "$cam $PERIOD: not joining, $day is not encoded yet"
      return 0
    }
  done

  for day in "${days[@]}"; do printf "file '%s'\n" "$DAYS/$cam-$day.mkv"; done >"$tmp/chunks"
  {
    printf '# timelapse %s %s: frame N is %d-minute slot N of the period, %d fps\n' \
      "$cam" "$PERIOD" "$SLOT_MINUTES" "$FPS"
    printf '# frame\tutc\tstatus\tsource\n'
    for day in "${days[@]}"; do
      awk -v day="$day" -v base="$((i++ * SLOTS_PER_DAY))" -v OFS='\t' \
        '{ print $1 + base, day "T" $2 "Z", $3, $4 }' "$DAYS/$cam-$day.tsv"
    done
  } >"$manifest"

  log "$cam $PERIOD: joining ${#days[@]} days"
  ffmpeg -hide_banner -loglevel warning -nostats -y \
    -f concat -safe 0 -i "$tmp/chunks" -c copy \
    -attach "$manifest" -metadata:s:t:0 mimetype=text/plain \
    -metadata:s:t:0 filename="$cam-$PERIOD.frames.tsv" -metadata "title=$cam $PERIOD" \
    -metadata "comment=one frame per $SLOT_MINUTES minutes from $(date -u -d "@$START" +%Y-%m-%dT%H:%M:%SZ) UTC; svt-av1 crf=$CRF preset=$PRESET 10-bit" \
    "$work" || {
    rm -f "$work"
    die "$cam: joining the days failed"
  }

  cp "$manifest" "$OUT/$cam-$PERIOD.frames.tsv"
  mv "$work" "$video"
  log "$cam $PERIOD: wrote $video ($(du -h "$video" | cut -f1))"
}

[ "$PERIOD_MODE" = month ] || mkdir -p "$DAYS"
for cam in "${cameras[@]}"; do
  if [ "$PERIOD_MODE" = month ]; then
    join_month "$cam"
  elif [ -e "$OUT/$cam-${PERIOD%-*}.mkv" ]; then
    log "$cam $PERIOD: ${PERIOD%-*} is already a single video, nothing to do"
  else
    encode_day "$cam" "$PERIOD"
  fi
done

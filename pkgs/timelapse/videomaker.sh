# timelapse-videomaker: turn stills into archival video, a day at a time.
#
#   timelapse-videomaker 2026-07-03   encode that one day
#   timelapse-videomaker 2026-07      join that month's days into one video
#
# The timeline is wall-clock: frame N is 5-minute slot N of the period, always.
# Where several photos fall in one slot the earliest wins; the rest are not in
# the video. A photo stands in for up to HOLD slots of missing ones, beyond
# which the picture is greyed out and captioned, so an outage looks like an
# outage instead of a frozen camera. A day with no photos at all is a full day
# of that treatment, greyed over the last picture the camera managed to take,
# which may be days or months earlier.
#
# Nothing is ever drawn on the pixels of a real photograph: what the camera burnt
# into it is all the picture says. Which day a frame belongs to and where the
# camera was down are subtitle tracks, carried by every video this makes.
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

# Frozen by measurement. The day-level frame check below counts packets, which
# equals decoded frames for these settings; re-check that if they ever change.
CRF=35
PRESET=2
FPS=24
DUR=0.041666667      # one frame at 24 fps, written out because FPS is not a knob
# Half an hour of gap is held rather than marked: a flash reads worse than a stale
# picture, and a gap that long is nearly always part of a longer one anyway.
HOLD=6               # missing slots one photograph may stand in for
LOCAL_TZ=Europe/Vilnius # the gap captions read local time

ENCODED_AS="svt-av1 crf=$CRF preset=$PRESET 10-bit"

# The subtitle track, the same in a day video and in a month. Default, because a
# viewer should not have to go looking for it, and copied rather than encoded: only
# the ass demuxer is needed to mux one.
SUB_TRACK=(-c:s copy -disposition:s:0 default
  -metadata:s:s:0 title=timeline -metadata:s:s:0 language=eng)

usage() {
  cat <<'EOF'
Usage: timelapse-videomaker YYYY-MM-DD                 encode one day
       timelapse-videomaker --reconciled YYYY-MM          join that month for good

  --reconciled     the other host has just been asked for everything it holds for
                   this month, so the joined video may be made final. Required to
                   join, because a joined month is never rebuilt. By hand:
                   timelapse-merger --missing-from=HOST 2026-07 &&
                     timelapse-videomaker --reconciled 2026-07

Day videos go to /var/lib/timelapse-r11/videos/days/<camera>-<date>.mkv and
month videos to /var/lib/timelapse-r11/videos/<camera>-<month>.mkv, each carrying
the frame manifest that names the source photo behind every frame as an
attachment. Nothing about a video is kept outside it.

One frame per 5 minutes of wall-clock time, so a day is 288 frames and one
second of video is two hours. Missing stretches keep the pace: the last photo is
held for up to 30 minutes, then greyed out and captioned NO DATA until the camera
comes back. A day with no photos at all is greyed end to end over the last
picture the camera took, whenever that was.

Every video carries one subtitle track: the day a frame belongs to, in a corner,
and a red banner naming every outage with its local start time and length. A
month video also has a chapter per day. A joined month is read from the day videos
alone, so each of them says everything about itself.

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
# three: a change mid-concat reinitialises the filter graph and cfr then drops a
# frame, which the frame count below catches. Cameras do not all encode their
# JPEGs the same way, so read it.
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
      echo "$f"
      return
    }
  done < <(list_days "$ROOT/$1" | sort -r)
}

# One fixed-width line per slot: frame, state, source. Frame N therefore starts
# at byte N * MANIFEST_ROW, so any frame's record is one seek away, and a file
# whose size is not a multiple of that is truncated. The only place the
# photo/held/missing decision is made.
#
# The day directory is not written: a photo's name gives it, as ${name:0:10}.
write_manifest() { # cam day seed seed_age
  local day="$2" last="$3" f i name state
  local last_slot=$((-1000000))
  local -A src=()
  [ -z "$last" ] || last_slot=$((-$4))

  # A slot past the end of the day comes from a name that is not a time, and the
  # loop below would leave that photograph out of the manifest for good.
  while read -r f; do
    set_slot "$f"
    ((slot < SLOTS_PER_DAY)) ||
      die "$1 $day: $f is not named with a time of day; rename it"
    [ -n "${src[$slot]:-}" ] || src[$slot]="$f"
  done < <(list_photos "$ROOT/$1/$day")

  for ((i = 0; i < SLOTS_PER_DAY; i++)); do
    if [ -n "${src[$i]:-}" ]; then
      name=${src[$i]}
      last=$name
      last_slot=$i
      state=P
    elif [ -n "$last" ] && ((i - last_slot <= HOLD)); then
      name=$last
      state=H
    else
      name=$last
      state=M
    fi
    printf '%04d %s %-23s\n' "$i" "$state" "$name"
  done
}

manifest_to_concat() { # cam black < manifest
  local name path
  echo "ffconcat version 1.0"
  while read -r _ _ name; do
    if [ -z "$name" ]; then path=$2; else path=$ROOT/$1/${name:0:10}/$name; fi
    printf "file '%s'\nduration %s\n" "$path" "$DUR"
  done
}

# Every run of consecutive missing frames, as "first last": the filter that marks
# them and the subtitles that name them cannot then disagree about an outage.
missing_runs() { # < manifest
  local frame state start=-1 prev=-1
  while read -r frame state _; do
    if [ "$state" = M ]; then
      [ "$start" -ge 0 ] || start=$((10#$frame))
      prev=$((10#$frame))
    elif [ "$start" -ge 0 ]; then
      echo "$start $prev"
      start=-1
    fi
  done
  [ "$start" -lt 0 ] || echo "$start $prev"
}

runs_to_enable() { # < missing_runs
  local first last out=""
  while read -r first last; do out="$out+between(n\\,$first\\,$last)"; done
  echo "${out#+}"
}

encode_day() { # cam day
  local cam="$1" day="$2"
  local video="$DAYS/$cam-$day.mkv"
  local manifest="$tmp/manifest" concat="$tmp/concat"
  local seed seed_age=0 ref w h pix_fmt black vf enable work

  # What the video calls a photo slot comes out of the video: a day whose
  # manifest is unreadable is unfinished, and is encoded again.
  if manifest_of "$video" "$tmp/day.tsv"; then
    slots_on_disk "$cam" >"$tmp/ondisk"
    photo_slots "$tmp/day.tsv" >"$tmp/invideo"
    [ -n "$(comm -13 "$tmp/invideo" "$tmp/ondisk")" ] || return 0
    log "$cam $day: photos appeared for slots it calls missing, re-encoding"
  fi

  local day_epoch
  day_epoch=$(date -u -d "$day 00:00:00" +%s)
  seed=$(previous_photo "$cam" "$day")
  [ -z "$seed" ] ||
    seed_age=$(((day_epoch -
      $(date -u -d "${seed:0:10} ${seed:11:2}:${seed:14:2}:${seed:17:2}" +%s) +
      60 * SLOT_MINUTES - 1) / 60 / SLOT_MINUTES))

  ref=$(list_photos "$ROOT/$cam/$day")
  if [ -n "$ref" ]; then
    ref="$ROOT/$cam/$day/${ref%%$'\n'*}"
  elif [ -n "$seed" ]; then
    ref="$ROOT/$cam/${seed:0:10}/$seed"
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
  enable=$(missing_runs <"$manifest" | runs_to_enable)

  vf=""
  if [ -n "$enable" ]; then
    # The dimming is what timelapse-reap's pixel check sees a wrongly marked
    # frame by; the caption alone is invisible to it. Both run only over the
    # frames the manifest calls missing, so static text is all that is needed.
    vf="hue=s=0:enable=$enable,eq=brightness=-0.25:contrast=0.85:enable=$enable"
    # Opaque box, not a translucent one: flat black behind bright red is cheap
    # to code and survives crf 35 on a dimmed static frame.
    vf="$vf,drawtext=fontfile=$TIMELAPSE_FONT:text='NO DATA':fontcolor=red"
    vf="$vf:fontsize=h/18:box=1:boxcolor=black:boxborderw=18"
    vf="$vf:x=(w-text_w)/2:y=h-text_h-40:enable=$enable,"
  fi
  local -a codec=(-c:v libsvtav1 -preset "$PRESET" -crf "$CRF"
    -pix_fmt yuv420p10le -g $((FPS * 10)))
  vf="${vf}format=yuv420p10le"

  write_cues "$manifest" "$tmp/cues.ass" "$w" "$h"

  local progress=(-nostats)
  [ ! -t 2 ] || progress=(-stats -stats_period 10)
  work="$DAYS/.$cam-$day.$$.part.mkv"
  log "$cam $day: encoding into $SLOTS_PER_DAY frames"
  # Every input before any output option: one written after an -i is read as an
  # input option for that input instead.
  ffmpeg -hide_banner -loglevel warning "${progress[@]}" -y \
    -f concat -safe 0 -i "$concat" -i "$tmp/cues.ass" \
    -r "$FPS" -fps_mode cfr -vf "$vf" -map 0:v -map 1 \
    "${codec[@]}" "${SUB_TRACK[@]}" \
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

  # One file to publish, manifest and all, so nothing can be left half-published.
  mv "$work" "$video"
  log "$cam $day: wrote $video ($(du -h "$video" | cut -f1))"
}

# Frame $1 as an ASS timestamp.
ass_time() { # frame
  local cs=$(($1 * 100 / FPS))
  printf '%d:%02d:%02d.%02d' \
    $((cs / 360000)) $((cs / 6000 % 60)) $((cs / 100 % 60)) $((cs % 100))
}

# How long an outage lasted, in the units a reader wants: 45m, 2h, 2h 15m.
gap_length() { # minutes
  if [ "$1" -lt 60 ]; then
    printf '%dm' "$1"
  elif [ $(($1 % 60)) -eq 0 ]; then
    printf '%dh' $(($1 / 60))
  else
    printf '%dh %dm' $(($1 / 60)) $(($1 % 60))
  fi
}

# The day a frame belongs to, and every outage, in one track: a player displays a
# single subtitle track, so two would mean one of them never being seen. Both are
# read from the manifest, so neither can describe a video other than the one they
# are muxed into, and every video carries them -- a day video has to say
# everything about itself, because it is all the join reads.
#
# The date sits bottom left, clear of the clock the camera burns into the top
# right; an outage is red across the middle. The styles are in the frame's own
# coordinates so the text keeps its proportions, and the font is named rather than
# embedded, since any player has something close to hand.
write_cues() { # manifest out width height
  local i=0 day first last
  cat >"$2" <<EOF
[Script Info]
ScriptType: v4.00+
PlayResX: $3
PlayResY: $4

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Date,DejaVu Sans,$(($4 / 24)),&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,1,20,20,20,1
Style: Outage,DejaVu Sans,$(($4 / 12)),&H000000FF,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,3,0,5,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
  for day in "${days[@]}"; do
    printf 'Dialogue: 0,%s,%s,Date,,0,0,0,,%s\n' \
      "$(ass_time $((i * SLOTS_PER_DAY)))" "$(ass_time $(((i + 1) * SLOTS_PER_DAY)))" \
      "$(LC_ALL=C date -u -d "$day" +'%a %F')" >>"$2"
    i=$((i + 1))
  done
  while read -r first last; do
    printf 'Dialogue: 0,%s,%s,Outage,,0,0,0,,no data since %s (%s)\n' \
      "$(ass_time "$first")" "$(ass_time $((last + 1)))" \
      "$(TZ=$LOCAL_TZ date -d "@$((START + first * SLOT_MINUTES * 60))" +'%H:%M %Z')" \
      "$(gap_length $(((last - first + 1) * SLOT_MINUTES)))" >>"$2"
  done < <(missing_runs <"$1")
}

# A chapter per day, for a month only: a chapter over a whole 12-second day video
# would be no navigation at all.
write_chapters() { # chapters
  local i=0 day
  echo ';FFMETADATA1' >"$1"
  for day in "${days[@]}"; do
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\ntitle=%s\n' \
      "$((i * SLOTS_PER_DAY * 1000 / FPS))" "$(((i + 1) * SLOTS_PER_DAY * 1000 / FPS))" \
      "$day $(LC_ALL=C date -u -d "$day" +%a)" >>"$1"
    i=$((i + 1))
  done
}

join_month() { # cam
  local cam="$1" day i=0 w h
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
    [ -e "$DAYS/$cam-$day.mkv" ] || {
      log "$cam $PERIOD: not joining, $day is not encoded yet"
      return 0
    }
  done

  for day in "${days[@]}"; do printf "file '%s'\n" "$DAYS/$cam-$day.mkv"; done >"$tmp/chunks"
  {
    for day in "${days[@]}"; do
      # From each day video's own attachment, never the copy beside it: the day
      # videos are the whole of what a join reads, so nothing else on disk can
      # make the month describe frames other than the ones being joined.
      manifest_of "$DAYS/$cam-$day.mkv" "$tmp/day.tsv" ||
        die "$cam $PERIOD: $day's video carries no manifest of its own"
      # Nothing else ties a day video to the day it is being joined as, so two of
      # them swapped beforehand would be captioned as each other for good.
      [ "$(awk -v d="$day" \
        '$2 == "P" && substr($3, 1, length(d)) != d' "$tmp/day.tsv" | wc -l)" -eq 0 ] ||
        die "$cam $PERIOD: the manifest in $day's video is for a different day"
      awk -v base="$((i++ * SLOTS_PER_DAY))" \
        '{ printf "%04d %s %-23s\n", $1 + base, $2, $3 }' "$tmp/day.tsv"
    done
  } >"$manifest"

  # Made again from the month's own manifest rather than carried over from the
  # days: an outage across midnight is one gap, and the two days either side of it
  # would each report their half. The style follows the frame, which every day of a
  # joinable month shares.
  IFS=, read -r w h _ <<<"$(geometry "$DAYS/$cam-${days[0]}.mkv")"
  write_cues "$manifest" "$tmp/cues.ass" "$w" "$h"
  write_chapters "$tmp/chapters.txt"

  # The video stream is copied through untouched; the subtitles and chapters ride
  # beside it, and the manifest stays the first attachment, where readers look.
  log "$cam $PERIOD: joining ${#days[@]} days"
  ffmpeg -hide_banner -loglevel warning -nostats -y \
    -f concat -safe 0 -i "$tmp/chunks" -i "$tmp/cues.ass" -i "$tmp/chapters.txt" \
    -map 0:v -map 1 -map_chapters 2 -c:v copy "${SUB_TRACK[@]}" \
    -attach "$manifest" -metadata:s:t:0 mimetype=text/plain \
    -metadata:s:t:0 filename="$cam-$PERIOD.frames.tsv" -metadata "title=$cam $PERIOD" \
    -metadata "comment=one frame per $SLOT_MINUTES minutes from $(date -u -d "@$START" +%Y-%m-%dT%H:%M:%SZ) UTC; $ENCODED_AS" \
    "$work" || {
    rm -f "$work"
    die "$cam: joining the days failed"
  }

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

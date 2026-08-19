# timelapse-videomaker: turn stills into archival video, a day at a time.
#
#   timelapse-videomaker 2026-07-03   encode that one day
#   timelapse-videomaker 2026-07      join that month's days into one video
#
# The timeline is wall-clock: frame N is 5-minute slot N of the period, always.
# Where several photos fall in one slot the earliest wins; the rest are not in
# the video. A photo stands in for up to HOLD slots of missing ones, beyond
# which the picture is greyed out, so an outage looks like an outage instead of a
# frozen camera. A day with no photos at all is a full day of that treatment,
# greyed over the last picture the camera managed to take, which may be days or
# months earlier.
#
# No text is ever drawn into the pixels: what the camera burnt into a photograph is
# all the picture says, and the only mark this makes on an invented frame is the
# greying, which timelapse-reap reads. The day a frame belongs to and the outage it
# sits in are subtitles instead -- one event per frame, because a player that seeks
# past the start of an event is never sent it.
#
# Every time and date a viewer reads is local, LOCAL_TZ. UTC is for the machinery:
# the slots, the manifest, the chapter arithmetic, the provenance metadata.
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
QINDEX=121 # av1_vaapi CQP index, one value for both cameras
FPS=24
DUR=0.041666667      # one frame at 24 fps, written out because FPS is not a knob
# Half an hour of gap is held rather than marked: a flash reads worse than a stale
# picture, and a gap that long is nearly always part of a longer one anyway.
HOLD=6               # missing slots one photograph may stand in for
LOCAL_TZ=Europe/Vilnius # the gap captions read local time

ENCODED_AS="av1_vaapi cqp qindex=$QINDEX all-intra 10-bit"

# The subtitle track, the same in a day video and in a month. Default, because a
# viewer should not have to go looking for it, and copied rather than encoded: only
# the ass demuxer is needed to mux one.
SUB_TRACK=(-c:s copy -disposition:s:0 default
  -metadata:s:s:0 title=timeline -metadata:s:s:0 language=eng)

usage() {
  cat <<'EOF'
Usage: timelapse-videomaker YYYY-MM-DD   encode one day
       timelapse-videomaker YYYY-MM      join that month's days into one video

Day videos go to /var/lib/timelapse-r11/videos/days/<camera>-<date>.mkv and
month videos to /var/lib/timelapse-r11/videos/<camera>-<month>.mkv, each carrying
the frame manifest that names the source photo behind every frame as an
attachment. Nothing about a video is kept outside it.

One frame per 5 minutes of wall-clock time, so a day is 288 frames and one
second of video is two hours. Missing stretches keep the pace: the last photo is
held for up to 30 minutes, then greyed out until the camera comes back. A day with
no photos at all is greyed end to end over the last picture the camera took,
whenever that was. Nothing is written into the picture itself.

Every video carries one subtitle track, with an event for every single frame: the
day that frame belongs to, in a corner, and while the camera is down a red banner
saying when it went and how long it has been down by then, counting up. Per frame
because seeking is how these are watched, and a player is only sent the events
that start after where it landed. A month video also has a chapter per day. A
joined month is read from the day videos alone, so each of them says everything
about itself.

A finished video is never rebuilt. timelapse-daily merges a month from the other
host before it encodes any of its days, so every photograph a day will ever have
is already on disk when it is made. Joining a month needs every one of its days,
and by then each of them has been made that way. A day whose video turns out to
be older than a photograph of that day is dropped instead of joined, and made
again after the next merge. timelapse-daily normally drives both steps;
timelapse-reap checks the result.
EOF
}

PERIOD=""
while [ $# -gt 0 ]; do
  case "$1" in
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
# three, and so does every photograph of a day: a change mid-concat reinitialises
# the filter graph, which cannot be done with a hardware upload in it, and the
# encode fails. Cameras do not all encode their JPEGs the same way, so read it.
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
    # A seed is read back as a path built from its name, so one whose directory
    # disagrees names either nothing or another day's picture.
    [ -z "$f" ] || [ "${f:0:10}" = "$d" ] ||
      die "$1: $d/$f is not in the day its own name gives; move it"
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

# Every run of consecutive missing frames, as "first last source": the filter that
# marks them and the subtitles that name them cannot then disagree about an outage.
#
# The source is the photograph those frames are standing in for, which every
# missing row names, and it is when the data really stopped -- a run begins HOLD
# slots after it, so the run's own first frame is half an hour of lie. Empty when
# the camera had taken nothing at all yet.
missing_runs() { # < manifest
  local frame state name start=-1 prev=-1 held=""
  while read -r frame state name; do
    if [ "$state" = M ]; then
      [ "$start" -ge 0 ] || {
        start=$((10#$frame))
        held=$name
      }
      prev=$((10#$frame))
    elif [ "$start" -ge 0 ]; then
      echo "$start $prev $held"
      start=-1
    fi
  done
  [ "$start" -lt 0 ] || echo "$start $prev $held"
}

runs_to_enable() { # < missing_runs
  local first last out=""
  while read -r first last _; do out="$out+between(n\\,$first\\,$last)"; done
  echo "${out#+}"
}

encode_day() { # cam day
  local cam="$1" day="$2"
  local video="$DAYS/$cam-$day.mkv"
  local manifest="$tmp/manifest" concat="$tmp/concat"
  local seed seed_age=0 epoch ref w h pix_fmt black vf enable work

  # A day video that exists is not made again here: its month was merged from the
  # other host before it was made, so every photograph it will ever have was
  # already there. One that turns up regardless is join_month's to catch, and it
  # drops this video so the next run encodes the day again.
  [ ! -e "$video" ] || return 0

  local day_epoch
  day_epoch=$(date -u -d "$day 00:00:00" +%s)
  seed=$(previous_photo "$cam" "$day")
  [ -z "$seed" ] || {
    photo_epoch "$seed"
    seed_age=$(((day_epoch - epoch + 60 * SLOT_MINUTES - 1) / 60 / SLOT_MINUTES))
  }

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
    # The one mark on an invented frame, and not decoration: the greying is what
    # timelapse-reap's pixel check sees a wrongly marked frame by. What the outage
    # was is said by the subtitle, which no quantizer can smear and no viewer has
    # to read out of the picture. Runs only over the frames the manifest calls
    # missing, so the photographs themselves are untouched.
    vf="hue=s=0:enable=$enable,eq=brightness=-0.25:contrast=0.85:enable=$enable,"
  fi
  # Measured on this footage and this silicon (Radeon 780M): 170 MB a day against
  # 119 for svt-av1, every sampled frame scoring 0.989 or better against its own
  # photograph, in four seconds instead of minutes. -g 1 is not a knob: an
  # inter-predicted frame following a dimmed one scores 0.81, under the floor
  # timelapse-reap holds videos to. The driver silently ignores -qp and refuses
  # ICQ, QVBR, -compression_level, -tiles and B-frames.
  local -a codec=(-c:v av1_vaapi -rc_mode CQP -global_quality "$QINDEX" -g 1)
  # The CPU ladder, kept for the day this process is proven and the encoder moves
  # back off the GPU. Restoring it also means the vf tail below going back to
  # format=yuv420p10le and -vaapi_device dropped from the ffmpeg call:
  # local CRF=35 PRESET=2
  # local -a codec=(-c:v libsvtav1 -preset "$PRESET" -crf "$CRF"
  #   -pix_fmt yuv420p10le -g $((FPS * 10)))
  # The filters run on CPU frames -- the dimming timelapse-reap's pixel check
  # reads is drawn there -- and only the upload to the encoder comes after them.
  vf="${vf}format=p010,hwupload"

  write_cues "$manifest" "$tmp/cues.ass" "$w" "$h"

  local progress=(-nostats)
  [ ! -t 2 ] || progress=(-stats -stats_period 10)
  work="$DAYS/.$cam-$day.$$.part.mkv"
  log "$cam $day: encoding into $SLOTS_PER_DAY frames"
  # Every input before any output option: one written after an -i is read as an
  # input option for that input instead. The render node is named rather than
  # guessed, because ffmpeg picks no VAAPI device on its own.
  ffmpeg -hide_banner -loglevel warning "${progress[@]}" -y \
    -vaapi_device /dev/dri/renderD128 \
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

# Frame $1 as an ASS timestamp, in $ass. Assigns rather than echoes, like
# set_slot: there are two of these for every frame of every video, and a subshell
# each would cost more than the encode.
ass_time() { # frame
  local cs=$(($1 * 100 / FPS))
  printf -v ass '%d:%02d:%02d.%02d' \
    $((cs / 360000)) $((cs / 6000 % 60)) $((cs / 100 % 60)) $((cs % 100))
}

# How long an outage has run by now, in the units a reader wants: 45m, 2h, 2h 15m,
# and past a day 5d or 5d 5h, where minutes are noise beside days. In $gap.
# Assigns for the same reason ass_time does.
gap_length() { # minutes
  local h=$(($1 / 60)) d=$(($1 / 1440))
  if [ "$1" -lt 60 ]; then
    printf -v gap '%dm' "$1"
  elif [ "$1" -lt 1440 ] && [ $(($1 % 60)) -eq 0 ]; then
    printf -v gap '%dh' "$h"
  elif [ "$1" -lt 1440 ]; then
    printf -v gap '%dh %dm' "$h" $(($1 % 60))
  elif [ $((h % 24)) -eq 0 ]; then
    printf -v gap '%dd' "$d"
  else
    printf -v gap '%dd %dh' "$d" $((h % 24))
  fi
}

# The day a frame belongs to, and every outage, in one track: a player displays a
# single subtitle track, so two would mean one of them never being seen. Both are
# read from the manifest, so neither can describe a video other than the one they
# are muxed into, and every video carries them -- a day video has to say
# everything about itself, because it is all the join reads.
#
# Both sit along the bottom, clear of the clock the camera burns into the top
# right: the date far left, the outage red and centred, which at either camera's
# width leaves the two of them a wide gap. Out of the middle of the picture, since
# a dimmed frame is still worth watching. The styles are in the frame's own
# coordinates so the text keeps its proportions, and the font is named rather than
# embedded, since any player has something close to hand.
#
# One event per frame, both kinds. Matroska hands a subtitle event to the player as
# a single packet at its start time, so a player that seeks past that point is
# never sent it: a date event spanning a day left the date blank for anyone who
# scrubbed into that day, and an outage event spanning a gap showed nothing until
# the next gap began. A frame of dialogue means every seek lands inside one. It is
# also what lets the outage count up instead of stating a total, which is what a
# gap being watched rather than read wants.
write_cues() { # manifest out width height
  local frame start end ass gap since epoch ri=0 rfirst=-1 rlast=-1 rheld=""
  local rsince=0 rlocal="" rday=""
  local -a runs=() badges=()
  cat >"$2" <<EOF
[Script Info]
ScriptType: v4.00+
PlayResX: $3
PlayResY: $4

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Date,DejaVu Sans,$(($4 / 24)),&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,1,20,20,20,1
Style: Outage,DejaVu Sans,$(($4 / 18)),&H000000FF,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,3,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
  # The runs of missing frames, so the filter that greys them and the subtitles
  # that name them cannot disagree about when an outage began.
  mapfile -t runs < <(missing_runs <"$1")
  # The badge of every frame: the day it belongs to where the camera stands, which
  # is what somebody reading it means by today. A day video is still a UTC day and
  # so are its chapters -- only this line is for a human -- so the badge turns over
  # part way through, at local midnight, and the captions below agree with it.
  # One call: date reads a list of instants on stdin, and a subshell per frame
  # would cost more than the encode does.
  mapfile -t badges < <(for ((frame = 0; frame < NSLOTS; frame++)); do
    echo "@$((START + frame * SLOT_MINUTES * 60))"
  done | LC_ALL=C TZ=$LOCAL_TZ date -f - +'%a %F')
  # In timestamp order, which is what muxing them demands, and one open file.
  {
    ass_time 0
    end=$ass
    for ((frame = 0; frame < NSLOTS; frame++)); do
      # The end of one frame is the start of the next, so it is computed once. At
      # the top of the loop, because the outage below leaves it by continue.
      start=$end
      ass_time "$((frame + 1))"
      end=$ass
      printf 'Dialogue: 0,%s,%s,Date,,0,0,0,,%s\n' \
        "$start" "$end" "${badges[frame]}"

      # The outage banner, all of it: which run this frame falls in, when the
      # camera last managed a photograph, and how long ago that is by this frame.
      # The last photograph rather than the run's own start, because the held
      # frames between them are that same picture and the data stopped when it was
      # taken. It may be from another day, or from before the archive begins, in
      # which case there is nothing to count from but the run itself.
      while ((rlast < frame)) && ((ri < ${#runs[@]})); do
        read -r rfirst rlast rheld <<<"${runs[ri]}"
        ri=$((ri + 1))
        rsince=$((START + rfirst * SLOT_MINUTES * 60))
        [ -z "$rheld" ] || { photo_epoch "$rheld"; rsince=$epoch; }
        # One spawn for both faces, and rday takes the badge's own shape, so the
        # comparison below cannot rot if the badge format ever changes.
        IFS=';' read -r rday rlocal < \
          <(LC_ALL=C TZ=$LOCAL_TZ date -d "@$rsince" +'%a %F;%H:%M %Z')
      done
      ((frame >= rfirst && frame <= rlast)) || continue
      # A bare time is read as today's, so one from another day says which. The
      # comparison is per frame: a gap that runs over midnight is bare while it is
      # still the same day and dated from there on.
      since=$rlocal
      [ "$rday" = "${badges[frame]}" ] || since="${rday:9:5} $rlocal"
      # To the nearest minute: a camera that fires two seconds into its slot would
      # otherwise read a minute short of the truth.
      gap_length $(((START + frame * SLOT_MINUTES * 60 - rsince + 30) / 60))
      printf 'Dialogue: 0,%s,%s,Outage,,0,0,0,,no data since %s (%s)\n' \
        "$start" "$end" "$since" "$gap"
    done
  } >>"$2"
}

# A chapter per day, for a month only: a chapter over a whole 12-second day video
# would be no navigation at all.
#
# A viewer reads local dates, and this title is a UTC one -- which here is the same
# thing. A chapter opens at 00:00 UTC of its day, which is 02:00 or 03:00 that same
# morning in Vilnius at either offset, DST switch days included, so the UTC date it
# names is the local date the chapter opens on. Nothing to convert; if the zone
# ever moved west of UTC, this would have to be localised like the badge.
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
  local cam="$1" day i=0 w h late late_days
  local video="$OUT/$cam-$PERIOD.mkv" manifest="$tmp/month.tsv" work="$OUT/.$cam-$PERIOD.$$.part.mkv"

  [ ! -e "$video" ] || {
    log "$cam $PERIOD: already joined, skipping"
    return 0
  }
  # This video is final: nothing rebuilds a joined month. Every one of its days
  # has to be a video before there is anything to join at all; whether each of
  # them was encoded after the merge is the check below the manifest.
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

  # Merge-before-encode says every photograph of these days was already on disk
  # when each of them was encoded. A slot holding one the month claims nothing for
  # says it was not, so those days go: the next run encodes them after merging and
  # joins the month then.
  photo_slots "$manifest" >"$tmp/invideo"
  slots_on_disk "$cam" >"$tmp/ondisk"
  # Assigned rather than read through a process substitution, whose status a
  # mapfile throws away: a mapping that failed would come back empty and join.
  late=$(comm -13 "$tmp/invideo" "$tmp/ondisk" |
    while read -r s; do echo "${days[s / SLOTS_PER_DAY]}"; done | sort -u)
  [ -z "$late" ] || {
    mapfile -t late_days <<<"$late"
    for day in "${late_days[@]}"; do rm -f "$DAYS/$cam-$day.mkv"; done
    log "$cam $PERIOD: dropped the day videos of ${late_days[*]}: a photograph arrived after each was encoded, so they are made again after the next merge"
    return 0
  }

  # Made again from the month's own manifest rather than carried over from the
  # days: an outage across midnight is one gap, and the two days either side of it
  # would each report their half. The style follows the frame, which every day of a
  # joinable month shares.
  IFS=, read -r w h _ <<<"$(geometry "$DAYS/$cam-${days[0]}.mkv")"
  write_cues "$manifest" "$tmp/cues.ass" "$w" "$h"
  write_chapters "$tmp/chapters.txt"

  # The video stream is copied through untouched; the subtitles and chapters ride
  # beside it, and the manifest stays the first attachment, where readers look. The
  # comment is provenance for whatever reads this file later, so it is in UTC and
  # says so; everything a person reads off the picture is local.
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

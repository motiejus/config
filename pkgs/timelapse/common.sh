# Sourced by every timelapse tool at startup, so the awkward parts — above all
# the date arithmetic — exist once.

TOOL=${0##*/}
ROOT=/var/lib/timelapse-r11
OUT=$ROOT/videos
DAYS=$OUT/days
SLOT_MINUTES=5
SLOTS_PER_DAY=288 # 1440 / SLOT_MINUTES
MANIFEST_ROW=31   # bytes per manifest line: "NNNN S " + 23-char name + newline
MIN_BYTES=1024    # a failed capture leaves a 0-byte file; anything this small is not a photo

# A photo's name is its timestamp, and a slot is read straight out of fixed
# character positions in it, so anything else lands under whichever digits happen
# to sit there. Recovery copies prefixed "local-" exist in this tree.
PHOTO_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9].jpg'

# Every timestamp handled here is UTC. Only the gap captions of a month video
# read local time.
export TZ=UTC

die() {
  echo "$TOOL: $*" >&2
  exit 1
}
log() { echo "$TOOL: $*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The month after $1 (YYYY-MM), by month index.
#
# Never use date's relative syntax for this: in "2026-07-01 00:00:00 + 1 month"
# the "+ 1" is read as a UTC offset and the month silently comes out an hour
# short. A UTC day, on the other hand, is always exactly 86400 seconds.
next_month() {
  local i=$((10#${1%%-*} * 12 + 10#${1#*-}))
  printf '%d-%02d\n' $((i / 12)) $((i % 12 + 1))
}

# From $PERIOD (YYYY-MM or YYYY-MM-DD), set the half-open window [START, END),
# how many slots it holds, and the days it spans.
parse_period() {
  case "$PERIOD" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9])
    PERIOD_MODE=month
    START=$(date -u -d "$PERIOD-01 00:00:00" +%s) || die "invalid period: $PERIOD"
    END=$(date -u -d "$(next_month "$PERIOD")-01 00:00:00" +%s)
    ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
    PERIOD_MODE=day
    START=$(date -u -d "$PERIOD 00:00:00" +%s) || die "invalid period: $PERIOD"
    END=$((START + 86400))
    ;;
  *) die "period must be YYYY-MM or YYYY-MM-DD, got: $PERIOD" ;;
  esac
  NSLOTS=$(((END - START) / 60 / SLOT_MINUTES))
  mapfile -t days < <(for ((t = START; t < END; t += 86400)); do date -u -d "@$t" +%F; done)
}

find_cameras() {
  mapfile -t cameras < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -path "$OUT" -printf '%f\n' | sort)
  [ "${#cameras[@]}" -gt 0 ] || die "no camera directories under $ROOT"
}

# Sorted basenames of the usable photos in one day directory. A day the camera
# never ran has no directory at all, which is normal and must not be an error.
list_photos() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -type f -name "$PHOTO_GLOB" -size "+$((MIN_BYTES - 1))c" -printf '%f\n' | sort
}

# Day directories of one camera.
list_days() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
}

# One camera's photos whose names start with $2 (a period: YYYY-MM or
# YYYY-MM-DD). Trailing arguments go to find, so a caller can count them, delete
# them, or stop at the first one.
photos_in() { # cam prefix [find args...]
  local cam=$1 prefix=$2
  shift 2
  find "$ROOT/$cam" -mindepth 2 -maxdepth 2 -type f \
    -name "$prefix*" -name "$PHOTO_GLOB" -size "+$((MIN_BYTES - 1))c" "$@"
}

# Months that still hold photographs, oldest first. Day directories are not the
# same question: an empty one, or one holding only failed captures, is not a
# month any tool will ever encode, and asking about it every night never ends.
photo_months() {
  find "$ROOT" -mindepth 3 -maxdepth 3 -type f -name "$PHOTO_GLOB" \
    -size "+$((MIN_BYTES - 1))c" -printf '%f\n' | cut -d- -f1,2 | sort -u
}

# Whether month $1 is already a single video for every camera. A camera with no
# photographs at all is not waited on: a stray directory beside the cameras, or
# one taken out of service, can never get a video, and waiting for one waits
# forever. Any camera that has photographs anywhere is waited on for every month,
# including a month it has none of: the other host may hold the only copy of it,
# and a month skipped here is skipped for good.
joined() { # month
  local cam
  for cam in "${cameras[@]}"; do
    [ ! -e "$OUT/$cam-$1.mkv" ] || continue
    [ -z "$(photos_in "$cam" "" -printf . -quit)" ] || return 1
  done
}

# Sets $slot to the 5-minute slot a photo belongs to, counted within its own
# day, from its name: YYYY-MM-DD_HH:MM:SS.jpg. Assigns rather than echoes
# because it is called once per photo, and a subshell per photo is not free.
set_slot() { slot=$(((10#${1:11:2} * 60 + 10#${1:14:2}) / SLOT_MINUTES)); }

# The manifest a video carries, written to $2, false when it carries none.
# -dump_attachment writes the file and then exits non-zero for want of an output
# file, so the file is what there is to test.
manifest_of() { # video out
  rm -f "$2"
  ffmpeg -v error -y -dump_attachment:t:0 "$2" -i "$1" 2>/dev/null || true
  [ -s "$2" ]
}

# The slots a manifest holds a photograph for, numbered the way slots_on_disk
# numbers them and sorted the same plain way, which is what comm needs of both.
# Prints nothing when the whole period is missing, which is not an error.
photo_slots() { # manifest
  awk '$2 == "P" { print $1 + 0 }' "$1" | sort
}

# The slots of $PERIOD that have a photo on disk, ascending. Slots are numbered
# from the start of the period, so each day contributes its own 288. Which day a
# photo belongs to is read from its name, not from the directory it sits in, so
# this asks exactly the question the deletion answers: a photograph filed under
# another day is judged in the period that will delete it. Sorted as text, which
# is what comm needs from both of its inputs.
slots_on_disk() { # cam
  local f day i=0
  local -A day_index=()
  for day in "${days[@]}"; do day_index[$day]=$((i++)); done
  while read -r f; do
    day=${f:0:10}
    [ -n "${day_index[$day]:-}" ] ||
      die "$1 $PERIOD: $f is named for $day, which is not a day of $PERIOD"
    set_slot "$f"
    # A name the glob admits but the clock does not -- 23:60 onwards, not just an
    # hour past 23 -- gives a slot past its own day, which would otherwise land on
    # another day's row and ask about a frame this photo has nothing to do with.
    # Nothing downstream would notice: errexit is inert in reap_camera, because it
    # is called as (reap_camera "$cam") || failed=1, so every check here has to be
    # an explicit || die.
    ((slot < SLOTS_PER_DAY)) ||
      die "$1 $PERIOD: $f is not named with a time of day; rename it"
    echo $((day_index[$day] * SLOTS_PER_DAY + slot))
  done < <(photos_in "$1" "$PERIOD" -printf '%f\n') >"$tmp/disk-slots"
  sort -u "$tmp/disk-slots"
}

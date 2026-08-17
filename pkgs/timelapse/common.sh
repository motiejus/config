# Sourced by every timelapse tool at startup, so the awkward parts — above all
# the date arithmetic — exist once.

TOOL=${0##*/}
ROOT=/var/lib/timelapse-r11
OUT=$ROOT/videos
DAYS=$OUT/days
MERGED=$OUT/merged # one file per month timelapse-merger has reconciled, see join_month
SLOT_MINUTES=5
SLOTS_PER_DAY=288 # 1440 / SLOT_MINUTES
MIN_BYTES=1024    # a failed capture leaves a 0-byte file; anything this small is not a photo

die() {
  echo "$TOOL: $*" >&2
  exit 1
}
log() { echo "$TOOL: $*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The month after $1 (YYYY-MM).
#
# Never use date's relative syntax for this: in "2026-07-01 00:00:00 + 1 month"
# the "+ 1" is read as a UTC offset and the month silently comes out an hour
# short. Roll the month over by hand; a UTC day is always exactly 86400 seconds.
next_month() {
  local year="${1%%-*}" month=$((10#${1#*-}))
  if [ "$month" -eq 12 ]; then
    echo "$((year + 1))-01"
  else
    printf '%s-%02d\n' "$year" "$((month + 1))"
  fi
}

# From $PERIOD (YYYY-MM or YYYY-MM-DD), set the half-open window [START, END),
# how many slots it holds, and the days it spans.
parse_period() {
  local t
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
  days=()
  t=$START
  while [ "$t" -lt "$END" ]; do
    days+=("$(date -u -d "@$t" +%F)")
    t=$((t + 86400))
  done
}

find_cameras() {
  mapfile -t cameras < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -path "$OUT" -printf '%f\n' | sort)
  [ "${#cameras[@]}" -gt 0 ] || die "no camera directories under $ROOT"
}

# Sorted basenames of the usable photos in one day directory. A day the camera
# never ran has no directory at all, which is normal and must not be an error.
list_photos() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -type f -name '*.jpg' -size "+$((MIN_BYTES - 1))c" -printf '%f\n' | sort
}

# Day directories of one camera.
list_days() {
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
}

# Sets $slot to the 5-minute slot a photo belongs to, counted within its own
# day, from its name: YYYY-MM-DD_HH:MM:SS.jpg. Assigns rather than echoes
# because it is called once per photo, and a subshell per photo is not free.
set_slot() { slot=$(((10#${1:11:2} * 60 + 10#${1:14:2}) / SLOT_MINUTES)); }
